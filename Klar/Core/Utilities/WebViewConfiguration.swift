import AppKit
import Foundation
import WebKit
import ObjectiveC
import CoreLocation


class WebViewConfiguration {
    static let shared = WebViewConfiguration()

    nonisolated static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.4 Safari/605.1.15"

    // One WebKit process pool for all of Klar's web views. A configuration
    // made with init() gets a pool of its own, and each pool lists every
    // installed font on the main thread before its first page loads — about
    // 40 ms for each new tab. `processPool` is deprecated as having no
    // effect, but it still decides this; it's set through KVC, so the
    // deprecated type isn't named here.
    private var sharedProcessPool: Any?

    private init() {}

    /// Puts the web views made from `configuration` in Klar's process pool.
    func useSharedProcessPool(in configuration: WKWebViewConfiguration) {
        if let sharedProcessPool {
            configuration.setValue(sharedProcessPool, forKey: "processPool")
        } else {
            sharedProcessPool = configuration.value(forKey: "processPool")
        }
    }

    // Create a standard WKWebViewConfiguration. `dataStore` is a space's
    // separate profile or the private tabs' (SpaceManager); the shared one
    // by default.
    func createConfiguration(dataStore: WKWebsiteDataStore = .default()) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        useSharedProcessPool(in: configuration)

        configuration.websiteDataStore = dataStore
        // Klar's own pages (What's New)
        configuration.setURLSchemeHandler(KlarSchemeHandler.shared, forURLScheme: KlarSchemeHandler.scheme)
        configuration.suppressesIncrementalRendering = false
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isTextInteractionEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Without web developer tools, it's turned on per web view only when
        // the inspector is opened (enableDeveloperTools(for:)): while it's on,
        // WebKit's console agent keeps the last ~100 console messages per
        // page, arguments included, even with no inspector attached.
        if Self.showsDeveloperTools {
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        
        // Enable Picture-in-Picture support for macOS (private API key)
        configuration.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")

        applyWebKitFeatureOverrides(on: configuration.preferences)
        applyPasskeySetting(on: configuration.preferences)

        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.applicationNameForUserAgent = "Klar"
        configuration.allowsInlinePredictions = true

        // Add geolocation bridge script
        addGeolocationBridgeScript(to: configuration)

        // Add media control script for audio/video tracking and mute support
        addMediaControlScript(to: configuration)

        // Add background color extraction script
        addBackgroundColorScript(to: configuration)

        // Add window drag detection script
        addWindowDragScript(to: configuration)

        // Add password autofill bridge — talks to AutofillCoordinator
        addAutofillBridgeScript(to: configuration)

        // Intercept blob: anchor clicks before the site can remove the element
        addBlobDownloadInterceptScript(to: configuration)

        // Report edits a reload would lose, so the tab isn't suspended
        addEditTrackingScript(to: configuration)

        PageIconLoader.installAppearanceObserver(on: configuration)

        // Known trackers don't load (TrackerBlocker; each navigation sets it
        // for the page's site)
        TrackerBlocker.shared.install(on: configuration)

        // Chrome extensions: one controller for every web view, so content
        // scripts and the extension APIs reach every page (ExtensionManager);
        // and an "Add to Klar" button on Chrome Web Store pages. Not in
        // private tabs (a data store that isn't kept): extensions could
        // otherwise read and keep what's browsed there.
        if dataStore.isPersistent {
            configuration.webExtensionController = ExtensionManager.shared.controller
            ChromeWebStoreButton.install(on: configuration)
        }

        return configuration
    }

    // Tells the tab's coordinator, once per document, that the user typed into
    // something the suspend-time form check can't see: a rich-text editor
    // (contenteditable), or any field inside a frame. Such a tab isn't
    // suspended until its main frame loads another document (see
    // TabWebViewCoordinator.checkSuspendable). One capture-phase listener per
    // document, removed after the first report.
    private func addEditTrackingScript(to configuration: WKWebViewConfiguration) {
        let script = #"""
        (function() {
            if (window.__klarEditTracking) return;
            window.__klarEditTracking = true;

            const isMainFrame = window.top === window;
            function onInput(event) {
                if (!event.isTrusted) return;
                const target = event.target;
                // Main-frame form fields are checked when it matters instead.
                if (isMainFrame && (target instanceof HTMLInputElement ||
                                    target instanceof HTMLTextAreaElement ||
                                    target instanceof HTMLSelectElement)) {
                    return;
                }
                document.removeEventListener('input', onInput, true);
                try {
                    window.webkit.messageHandlers.userEdited.postMessage(true);
                } catch (e) {}
            }
            document.addEventListener('input', onInput, true);
        })();
        """#

        let userScript = WKUserScript(
            source: script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(userScript)
    }

    private func addBlobDownloadInterceptScript(to: WKWebViewConfiguration) {
        // Two interception paths, because blob downloads come in two shapes:
        //
        //   (1) User clicks an <a download> that's actually in the DOM →
        //       caught by the document-level capture-phase listener.
        //
        //   (2) Site synthesizes a detached <a download>, never appends it,
        //       calls .click() programmatically, then drops it (the
        //       ElevenLabs / file-saver.js pattern). Click events on detached
        //       elements don't bubble anywhere — there's no document path —
        //       so we patch HTMLAnchorElement.prototype.click directly.
        //
        // Both paths read `anchor.download` synchronously, then forward the
        // blob to native via the existing `blobDownload` message handler.
        let script = """
        (function() {
            if (window.__klarBlobInterceptInstalled) return;
            window.__klarBlobInterceptInstalled = true;

            function forwardBlobDownload(blobUrl, filename) {
                fetch(blobUrl)
                    .then(r => r.blob())
                    .then(blob => {
                        const reader = new FileReader();
                        reader.onloadend = function() {
                            window.webkit.messageHandlers.blobDownload.postMessage({
                                dataUrl: reader.result,
                                filename: filename,
                                mimeType: blob.type || 'application/octet-stream',
                                size: blob.size,
                                originalBlobUrl: blobUrl
                            });
                        };
                        reader.readAsDataURL(blob);
                    })
                    .catch(error => {
                        console.error('Klar blob download failed:', error);
                    });
            }

            // Path 1: real DOM clicks on blob anchors.
            document.addEventListener('click', function(event) {
                const anchor = event.target && event.target.closest
                    ? event.target.closest('a[href^="blob:"]')
                    : null;
                if (!anchor) return;
                const blobUrl = anchor.href;
                const filename = anchor.download || anchor.getAttribute('download') || '';
                event.preventDefault();
                forwardBlobDownload(blobUrl, filename);
            }, true);

            // Path 2: programmatic .click() on detached blob anchors.
            const origClick = HTMLAnchorElement.prototype.click;
            HTMLAnchorElement.prototype.click = function() {
                if (typeof this.href === 'string' && this.href.indexOf('blob:') === 0) {
                    const blobUrl = this.href;
                    const filename = this.download || this.getAttribute('download') || '';
                    forwardBlobDownload(blobUrl, filename);
                    return;
                }
                return origClick.apply(this, arguments);
            };

            // Path 3: synthetic click via dispatchEvent. file-saver and friends
            // create a MouseEvent('click') and dispatch it on a detached anchor
            // — bypasses both the document listener and the .click() patch.
            const origDispatchEvent = EventTarget.prototype.dispatchEvent;
            EventTarget.prototype.dispatchEvent = function(event) {
                if (event && event.type === 'click' &&
                    this instanceof HTMLAnchorElement &&
                    typeof this.href === 'string' &&
                    this.href.indexOf('blob:') === 0) {
                    const blobUrl = this.href;
                    const filename = this.download || this.getAttribute('download') || '';
                    forwardBlobDownload(blobUrl, filename);
                    return true;
                }
                return origDispatchEvent.apply(this, arguments);
            };
        })();
        """

        let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        to.userContentController.addUserScript(userScript)
    }
    
    private func addGeolocationBridgeScript(to: WKWebViewConfiguration) {
        let script = """
        // Create a bridge for communicating with native Swift code
        class GeolocationBridge {
            constructor() {
                this.watchCallbacks = new Map();
                this.watchIdCounter = 1;
                
                // Listen for responses from native code
                window.addEventListener('message', (event) => {
                    if (!event.data || typeof event.data !== 'object' || event.data.type !== 'geolocation') return;
                    this.handleNativeResponse(event.data);
                });
            }
            
            getCurrentPosition(success, error, options = {}) {
                const requestId = 'current_' + Date.now() + '_' + Math.random();
                
                // Store callbacks temporarily
                window[requestId + '_success'] = success;
                window[requestId + '_error'] = error;
                
                // Send request to native code
                const request = {
                    method: 'getCurrentPosition',
                    requestId: requestId,
                    options: options
                };
                this.sendToNative(request);
            }
            
            watchPosition(success, error, options = {}) {
                const watchId = this.watchIdCounter++;
                const requestId = 'watch_' + watchId + '_' + Date.now();
                
                // Store callbacks for this watch
                this.watchCallbacks.set(watchId, { success, error, requestId });
                
                // Send request to native code
                this.sendToNative({
                    method: 'watchPosition', 
                    requestId: requestId,
                    watchId: watchId,
                    options: options
                });
                
                return watchId;
            }
            
            clearWatch(watchId) {
                if (this.watchCallbacks.has(watchId)) {
                    const { requestId } = this.watchCallbacks.get(watchId);
                    this.watchCallbacks.delete(watchId);
                    
                    this.sendToNative({
                        method: 'clearWatch',
                        watchId: watchId,
                        requestId: requestId
                    });
                }
            }
            
            sendToNative(data) {
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.geolocationBridge) {
                        window.webkit.messageHandlers.geolocationBridge.postMessage(data);
                    } else {
                        // Fallback to error
                        if (data.requestId) {
                            const errorCallback = window[data.requestId + '_error'];
                            if (errorCallback) {
                                errorCallback({
                                    code: 1,
                                    message: 'Geolocation bridge not available'
                                });
                            }
                        }
                    }
                } catch (e) {
                    // Handle error silently
                    if (data.requestId) {
                        const errorCallback = window[data.requestId + '_error'];
                        if (errorCallback) {
                            errorCallback({
                                code: 2,
                                message: 'Bridge communication failed'
                            });
                        }
                    }
                }
            }
            
            handleNativeResponse(data) {
                if (data.success) {
                    // Success response
                    if (data.requestId.startsWith('current_')) {
                        const successCallback = window[data.requestId + '_success'];
                        if (successCallback) {
                            successCallback(data.position);
                            // Clean up
                            delete window[data.requestId + '_success'];
                            delete window[data.requestId + '_error'];
                        }
                    } else if (data.requestId.startsWith('watch_')) {
                        const watchId = data.watchId;
                        const watchInfo = this.watchCallbacks.get(watchId);
                        if (watchInfo && watchInfo.success) {
                            watchInfo.success(data.position);
                        }
                    }
                } else {
                    // Error response
                    if (data.requestId.startsWith('current_')) {
                        const errorCallback = window[data.requestId + '_error'];
                        if (errorCallback) {
                            errorCallback(data.error);
                            // Clean up
                            delete window[data.requestId + '_success'];
                            delete window[data.requestId + '_error'];
                        }
                    } else if (data.requestId.startsWith('watch_')) {
                        const watchId = data.watchId;
                        const watchInfo = this.watchCallbacks.get(watchId);
                        if (watchInfo && watchInfo.error) {
                            watchInfo.error(data.error);
                        }
                    }
                }
            }
        }
        
        // Create the bridge instance
        const geolocationBridge = new GeolocationBridge();
        
        // Replace navigator.geolocation with our bridge
        if (navigator.geolocation) {
            Object.defineProperty(navigator, 'geolocation', {
                get: function() {
                    return {
                        getCurrentPosition: function(success, error, options) {
                            geolocationBridge.getCurrentPosition(success, error, options);
                        },
                        watchPosition: function(success, error, options) {
                            return geolocationBridge.watchPosition(success, error, options);
                        },
                        clearWatch: function(watchId) {
                            geolocationBridge.clearWatch(watchId);
                        }
                    };
                },
                set: function(value) {
                    // Prevent overriding
                },
                configurable: false
            });
        }
        """
        
        let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        to.userContentController.addUserScript(userScript)
        
        // Note: GeolocationBridge will be added per-tab in TabWebViewCoordinator
        // to properly associate each bridge with its tab ID
    }
    
    private func addMediaControlScript(to: WKWebViewConfiguration) {
        let script = MediaControlService.shared.generateMediaControlScript()
        // Main frame only: the mute and pause/resume scripts are evaluated in
        // the main frame (evaluateJavaScript), so copies in iframes — ads,
        // embeds — only did work nothing ever read.
        let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        to.userContentController.addUserScript(userScript)
    }
    
    private func addBackgroundColorScript(to: WKWebViewConfiguration) {
        // Add the dynamic background color update script
        let userScript = WKUserScript(
            source: BackgroundColorExtractor.dynamicUpdateScript, 
            injectionTime: .atDocumentEnd, 
            forMainFrameOnly: true
        )
        to.userContentController.addUserScript(userScript)
    }
    
    private func addWindowDragScript(to: WKWebViewConfiguration) {
        let dragScript = """
            (function() {
                const DRAGGABLE_AREA_HEIGHT = 50; // Top 50px is draggable

                // Tags that are inherently interactive — clicking any descendant
                // fires the parent (e.g. clicking a <span> inside an <a>).
                const INHERITLY_INTERACTIVE_TAGS = new Set([
                    'a', 'button', 'input', 'select', 'textarea', 'label',
                    'video', 'audio', 'canvas', 'iframe', 'embed', 'object',
                    'summary'
                ]);

                // ARIA roles that mark an individual element as interactive.
                // Container roles like 'navigation', 'menu', 'tablist' are
                // intentionally excluded — they group items but the items
                // themselves carry the click semantics.
                const INTERACTIVE_ROLES = new Set([
                    'button', 'link', 'menuitem', 'menuitemcheckbox',
                    'menuitemradio', 'tab', 'checkbox', 'radio', 'slider',
                    'spinbutton', 'textbox', 'searchbox', 'combobox',
                    'switch', 'option'
                ]);

                const INTERACTIVE_INPUT_TYPES = new Set([
                    'button', 'submit', 'reset', 'checkbox', 'radio', 'range'
                ]);

                const INTERACTIVE_CLASS_NAMES = [
                    'btn', 'button', 'link', 'clickable', 'interactive',
                    'pointer', 'dropdown-toggle', 'nav-link', 'menu-item'
                ];

                // Controls inside an element make it a region rather than a
                // control (a control can't hold another).
                const CONTROL_SELECTOR =
                    'a[href], button, input, select, textarea, [tabindex]:not([tabindex^="-"])';

                // `elements` is the click's path, from the element under the
                // pointer up: it goes into open shadow roots, where sites
                // build headers as web components (discogs.com's search
                // field), whose hosts are all elementFromPoint and
                // parentElement see.
                function isElementInteractive(elements) {
                    const MAX_DEPTH = 8;

                    for (let depth = 0; depth < MAX_DEPTH && depth < elements.length; depth++) {
                        const element = elements[depth];
                        if (element === document.body || element === document.documentElement) break;
                        const tagName = element.tagName.toLowerCase();

                        // Cascading checks — applied at every depth because
                        // their semantics propagate to descendants:
                        //   - inherently interactive tags: a click inside fires the ancestor
                        //   - inline onclick: click events bubble to the handler
                        if (INHERITLY_INTERACTIVE_TAGS.has(tagName)) {
                            return true;
                        }
                        if (element.hasAttribute('onclick')) {
                            return true;
                        }

                        // The remaining checks only run on the direct click
                        // target. Properties like role, tabindex, data-target,
                        // and class names DO NOT make descendants clickable —
                        // a <header data-target="..."> does not turn the empty
                        // space inside its child <nav> into a button. Walking
                        // them up the tree (the previous behaviour) was the
                        // root cause of broken drag-to-move on sites like
                        // github.com whose nav sits under such containers.
                        if (depth === 0) {
                            // contentEditable is inherited via the DOM, so
                            // checking the click target catches an editable
                            // ancestor too.
                            if (element.isContentEditable) {
                                return true;
                            }

                            const role = element.getAttribute('role');
                            if (role && INTERACTIVE_ROLES.has(role)) {
                                return true;
                            }

                            const type = element.getAttribute('type');
                            if (type && INTERACTIVE_INPUT_TYPES.has(type)) {
                                return true;
                            }

                            // A focusable element is a control, unless it
                            // holds controls: then it's a region made
                            // focusable so the keyboard can scroll it, like
                            // github.com's content pane (`tabindex="0"`),
                            // whose margins are the page's empty sides.
                            if (element.hasAttribute('tabindex')) {
                                const tabindex = parseInt(element.getAttribute('tabindex'), 10);
                                if (tabindex >= 0 && !element.querySelector(CONTROL_SELECTOR)) return true;
                            }

                            if (element.hasAttribute('data-clickable') ||
                                element.hasAttribute('data-toggle') ||
                                element.hasAttribute('data-target') ||
                                element.hasAttribute('ng-click') ||
                                element.hasAttribute('v-on:click') ||
                                element.hasAttribute('@click')) {
                                return true;
                            }

                            const classList = element.classList;
                            for (let i = 0; i < INTERACTIVE_CLASS_NAMES.length; i++) {
                                if (classList.contains(INTERACTIVE_CLASS_NAMES[i])) {
                                    return true;
                                }
                            }

                            // CSS `cursor` is inherited, so getComputedStyle on
                            // the direct target reflects the value any ancestor
                            // sets. This is the most reliable signal that the
                            // site itself considers the area clickable.
                            const computedStyle = window.getComputedStyle(element);
                            const cursor = computedStyle.cursor;
                            if (cursor === 'pointer' || cursor === 'grab' || cursor === 'grabbing') {
                                return true;
                            }

                            const isScrollable = computedStyle.overflow === 'auto' || computedStyle.overflow === 'scroll' ||
                                computedStyle.overflowX === 'auto' || computedStyle.overflowX === 'scroll' ||
                                computedStyle.overflowY === 'auto' || computedStyle.overflowY === 'scroll';

                            if (isScrollable && (element.scrollHeight > element.clientHeight || element.scrollWidth > element.clientWidth)) {
                                const elementRect = element.getBoundingClientRect();
                                const isInDraggableArea = elementRect.top < DRAGGABLE_AREA_HEIGHT;
                                if (!isInDraggableArea) {
                                    return true;
                                }
                                const scrollableRatio = Math.max(
                                    element.scrollHeight / element.clientHeight,
                                    element.scrollWidth / element.clientWidth
                                );
                                if (scrollableRatio > 1.2) {
                                    return true;
                                }
                            }
                        }
                    }

                    return false;
                }

                document.addEventListener('mousedown', function(event) {
                    // Only handle left mouse button
                    if (event.button !== 0) return;

                    // Check if we're in the draggable area (top 50px)
                    if (event.clientY > DRAGGABLE_AREA_HEIGHT) return;

                    // The element under the cursor and its ancestors
                    const elements = event.composedPath().filter(node => node instanceof Element);
                    if (elements.length === 0) return;

                    // If the element is interactive, don't start dragging
                    if (isElementInteractive(elements)) {
                        return;
                    }

                    // Prevent the default action so text selection / focus
                    // change does not race the native drag.
                    event.preventDefault();
                    event.stopPropagation();

                    // Send message to Swift to initiate the native window drag.
                    // The drag itself is handled synchronously on the Swift
                    // side via NSWindow.performDrag, so no JS-side state
                    // tracking is needed.
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.windowDrag) {
                        window.webkit.messageHandlers.windowDrag.postMessage({
                            action: 'startDrag',
                            x: event.clientX,
                            y: event.clientY
                        });
                    }
                }, true); // Use capture phase to catch events early
            })();
        """
        
        let userScript = WKUserScript(
            source: dragScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        to.userContentController.addUserScript(userScript)
    }

    // Injects the autofill content script. Classifies sign-in (username,
    // password), verification-code and contact fields as they gain focus,
    // and bridges focus/click/submit events to native (`autofillFieldFocused`,
    // `autofillIconClicked` with the field's kind, `autofillFormSubmitted`).
    // Native decides whether the key icon shows (`__klarAutofill.showIcon()`),
    // takes the site from the message's frame info rather than the page, and
    // sends fill commands back to that frame via `evaluateJavaScript`.
    private func addAutofillBridgeScript(to configuration: WKWebViewConfiguration) {
        let script = #"""
        (function() {
            'use strict';
            if (window.__klarAutofillInstalled) return;
            window.__klarAutofillInstalled = true;

            const KEY_GLYPH = \#(Self.autofillKeyGlyph);

            function isPasswordField(input) {
                return (input.type || '').toLowerCase() === 'password';
            }
            function isLikelyTextual(input) {
                const type = (input.type || '').toLowerCase();
                return type === '' || type === 'text' || type === 'email' || type === 'tel';
            }
            function isUsernameField(input) {
                const type = (input.type || '').toLowerCase();
                if (type === 'email' || type === 'tel') return true;
                if (type !== 'text' && type !== '') return false;
                const ac = (input.autocomplete || '').toLowerCase();
                if (ac.includes('username') || ac === 'email') return true;
                const tag = ((input.name || '') + ' ' + (input.id || '') + ' ' + (input.placeholder || '') + ' ' + (input.getAttribute('aria-label') || '')).toLowerCase();
                return /user|email|login|account|signin|sign-in|acct/.test(tag);
            }
            // OTP detection looks for the
            // one-time-code autocomplete token; names and labels that say so,
            // matched word by word so app_otp, otpAttempt and "Two-factor
            // code" all count; digits-only pattern attributes; rows of
            // single-digit boxes; and a weaker "code"/"pin" label backed by a
            // numeric hint.
            const STRONG_OTP_PHRASES = [
                'otp', 'totp', 'hotp', 'mfa', '2fa', 'tfa', '2sv', 'twofactor', 'two factor',
                'multifactor', 'multi factor', 'two step', '2 step', 'one time', 'onetime',
                'verification code', 'verificationcode', 'verify code', 'auth code', 'authcode',
                'authentication code', 'authenticator', 'security code', 'passcode', 'sms code',
                'login code', 'sign in code', 'signin code', 'confirmation code'
            ];
            const WEAK_OTP_WORDS = ['code', 'pin', 'token', 'digits', 'verification', 'verify'];
            const NOT_OTP_WORDS = [
                'card', 'cvv', 'cvc', 'csc', 'credit', 'expiry', 'expiration', 'postal', 'zip',
                'postcode', 'promo', 'coupon', 'discount', 'gift', 'voucher', 'referral', 'invite',
                'invitation', 'country', 'area', 'phone', 'tracking', 'search', 'captcha'
            ];

            // Lowercase words of an attribute or label, split on punctuation,
            // underscores and camelCase, padded so phrases match whole words.
            function wordString(text) {
                const words = String(text || '')
                    .replace(/([a-z])([A-Z])/g, '$1 $2')
                    .toLowerCase()
                    .split(/[^a-z0-9]+/)
                    .filter(Boolean);
                return ' ' + words.join(' ') + ' ';
            }
            function hasPhrase(words, phrase) {
                return words.includes(' ' + phrase + ' ');
            }
            function fieldDescription(input) {
                const parts = [input.name, input.id, input.placeholder, input.title,
                               input.getAttribute('aria-label')];
                if (input.labels) {
                    for (const label of input.labels) parts.push(label.textContent);
                }
                const labelledBy = input.getAttribute('aria-labelledby');
                if (labelledBy) {
                    const root = input.getRootNode();
                    for (const id of labelledBy.split(/\s+/)) {
                        const label = root.getElementById ? root.getElementById(id) : null;
                        if (label) parts.push(label.textContent);
                    }
                }
                return wordString(parts.filter(Boolean).map((part) => String(part).slice(0, 200)).join(' '));
            }
            function acceptsOnlyDigits(input) {
                const pattern = input.getAttribute('pattern');
                if (!pattern) return false;
                try {
                    const regex = new RegExp('^(?:' + pattern + ')$', 'v');
                    return (regex.test('1234') || regex.test('123456') || regex.test('12345678')) &&
                        !regex.test('a') && !regex.test('A');
                } catch (e) {
                    return false;
                }
            }
            // The row of single-character boxes some sites split a code
            // across, if `input` is one of them.
            function digitBoxes(input) {
                if (input.maxLength !== 1) return null;
                const parent = input.parentElement;
                const containers = [parent, parent && parent.parentElement,
                                    input.closest('fieldset'), input.closest('[role~="dialog"]')];
                for (const container of containers) {
                    if (!container) continue;
                    const boxes = Array.from(container.querySelectorAll('input'))
                        .filter((box) => box.type !== 'hidden');
                    if (boxes.length >= 4 && boxes.length <= 8 && boxes.includes(input) &&
                        boxes.every((box) => box.maxLength === 1)) {
                        return boxes;
                    }
                }
                return null;
            }
            function isOTPField(input) {
                if (hasPhrase(wordString(input.getAttribute('autocomplete')), 'one time code')) return true;
                if (hasPhrase(wordString((input.id || '') + ' ' + (input.name || '')), 'one time code')) return true;
                const type = (input.type || '').toLowerCase();
                if (type !== 'text' && type !== 'tel' && type !== 'number' && type !== '') return false;

                const words = fieldDescription(input);
                if (NOT_OTP_WORDS.some((word) => hasPhrase(words, word))) return false;
                if (STRONG_OTP_PHRASES.some((phrase) => hasPhrase(words, phrase))) return true;
                if (digitBoxes(input)) return true;

                const max = input.maxLength; // -1 when unset
                if (max > 10) return false;
                if (acceptsOnlyDigits(input)) return true;
                if (!WEAK_OTP_WORDS.some((word) => hasPhrase(words, word))) return false;

                const inputMode = (input.inputMode || '').toLowerCase();
                const placeholder = (input.placeholder || '').replace(/\s/g, '');
                return type === 'number' || type === 'tel' || inputMode === 'numeric' ||
                    (max >= 4 && max <= 8) || input.autofocus ||
                    /^\d{4,8}$/.test(placeholder) || /^(.)\1{3,7}$/u.test(placeholder);
            }
            // Contact fields, named by the HTML autocomplete token they take:
            // the autocomplete attribute when the page sets one, otherwise
            // words in the field's name, id and labels. Fillable from My Card.
            const CONTACT_TOKENS = new Set([
                'name', 'given-name', 'additional-name', 'family-name', 'organization', 'email',
                'tel', 'tel-national', 'street-address', 'address-line1', 'address-line2',
                'address-level1', 'address-level2', 'postal-code', 'country', 'country-name'
            ]);
            const CONTACT_PHRASES = [
                ['given-name', ['first name', 'firstname', 'given name', 'fname', 'forename']],
                ['family-name', ['last name', 'lastname', 'surname', 'family name', 'lname']],
                ['email', ['email', 'e mail']],
                ['tel', ['phone', 'telephone', 'mobile', 'tel', 'cell']],
                ['organization', ['company', 'organization', 'organisation', 'business name']],
                ['address-line2', ['address2', 'address line 2', 'apartment', 'apt', 'suite', 'unit']],
                ['address-line1', ['address1', 'address line 1', 'street', 'address']],
                ['address-level2', ['city', 'town', 'locality']],
                ['address-level1', ['state', 'province', 'region', 'county']],
                ['postal-code', ['zip', 'zipcode', 'postal', 'postcode', 'postal code', 'zip code']],
                // A box labelled Country wants a name; autocomplete="country"
                // (handled above) is the ISO code.
                ['country-name', ['country']],
                ['name', ['full name', 'fullname', 'your name', 'name']]
            ];
            const NOT_CONTACT_WORDS = ['user', 'username', 'login', 'search', 'coupon', 'promo', 'card', 'ip', 'web', 'url', 'captcha'];
            function contactFieldType(element) {
                const tokens = String(element.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
                const declared = tokens[tokens.length - 1];
                if (CONTACT_TOKENS.has(declared)) return declared;
                if (declared === 'off' || declared === '' || declared === 'on') {
                    const type = (element.type || '').toLowerCase();
                    if (type === 'email') return 'email';
                    if (type === 'tel') return 'tel';
                    const words = fieldDescription(element);
                    if (NOT_CONTACT_WORDS.some((word) => hasPhrase(words, word))) return null;
                    for (const [token, phrases] of CONTACT_PHRASES) {
                        if (phrases.some((phrase) => hasPhrase(words, phrase))) return token;
                    }
                }
                return null;
            }
            function formRoot(element) {
                return element.form || element.getRootNode();
            }
            // My Card only goes into boxes the user can see: a page could
            // otherwise collect an address through fields that are off-screen,
            // transparent, tiny or covered by other content. Fields below the
            // fold are skipped too; focusing one there offers My Card again.
            function isVisibleToUser(element) {
                if (element.disabled || element.readOnly) return false;
                if (element instanceof HTMLInputElement && (element.type === 'hidden' || element.type === 'password')) return false;
                const rect = element.getBoundingClientRect();
                if (rect.width < 8 || rect.height < 8) return false;
                const x = rect.left + rect.width / 2;
                const y = rect.top + rect.height / 2;
                if (x < 0 || y < 0 || x > window.innerWidth || y > window.innerHeight) return false;
                if (getComputedStyle(element).visibility !== 'visible') return false;
                for (let node = element; node; ) {
                    if (parseFloat(getComputedStyle(node).opacity) < 0.1) return false;
                    const root = node.getRootNode();
                    node = node.parentElement || (root instanceof ShadowRoot ? root.host : null);
                }
                const root = element.getRootNode();
                const hit = (root.elementFromPoint ? root : document).elementFromPoint(x, y);
                if (!hit) return false;
                if (hit === element || element.contains(hit)) return true;
                // A label drawn over its own box (floating labels) still counts.
                return Array.from(element.labels || []).some((label) => label === hit || label.contains(hit));
            }
            // Contact boxes My Card may fill alongside `anchor`: visible ones
            // in its own form (or fieldset or dialog), or just the anchor when
            // it isn't in one.
            function fillableContactFields(anchor) {
                const scope = anchor.form || anchor.closest('fieldset, [role="form"], [role="dialog"]');
                const candidates = scope ? scope.querySelectorAll('input, select, textarea') : [anchor];
                const fields = [];
                for (const element of candidates) {
                    const type = contactFieldType(element);
                    if (type && isVisibleToUser(element)) fields.push([element, type]);
                }
                return fields;
            }
            function inSignInForm(input) {
                return !!formRoot(input).querySelector('input[type="password"]');
            }
            // Other contact fields alongside this one, so a lone email box
            // (often the first step of a sign-in) isn't taken for an address
            // form.
            function hasContactNeighbours(input) {
                const fields = formRoot(input).querySelectorAll('input, select, textarea');
                let count = 0;
                for (const field of fields) {
                    if (field !== input && field.type !== 'hidden' && contactFieldType(field)) count++;
                    if (count >= 1) return true;
                }
                return false;
            }
            // Find the nearest preceding text-ish input — used as a fallback
            // when isUsernameField's heuristics miss (e.g. <input name="acct">
            // on news.ycombinator.com).
            function findRelatedUsername(passwordField) {
                const root = passwordField.form || passwordField.getRootNode();
                const inputs = Array.from(root.querySelectorAll('input'));
                const idx = inputs.indexOf(passwordField);
                for (let i = idx - 1; i >= 0; i--) {
                    if (isLikelyTextual(inputs[i])) return inputs[i];
                }
                return null;
            }
            function findRelatedPassword(usernameField) {
                const root = usernameField.form || usernameField.getRootNode();
                return root.querySelector('input[type="password"]');
            }
            // A text-ish input that is the nearest one before a password
            // field is a username candidate regardless of name/id/placeholder.
            // Catches sites like Hacker News where the username field is
            // just <input name="acct">.
            function precedesPasswordField(input) {
                if (!isLikelyTextual(input)) return false;
                const passwords = input.getRootNode().querySelectorAll('input[type="password"]');
                for (let i = 0; i < passwords.length; i++) {
                    if (findRelatedUsername(passwords[i]) === input) return true;
                }
                return false;
            }
            // 'otp', 'password', 'username' or 'contact' for fields Klar
            // offers to fill.
            function classify(input) {
                if (isOTPField(input)) return 'otp';
                if (isPasswordField(input)) return 'password';
                const autocomplete = wordString(input.getAttribute('autocomplete'));
                if (hasPhrase(autocomplete, 'username') || hasPhrase(autocomplete, 'webauthn')) return 'username';
                if (inSignInForm(input)) {
                    return isUsernameField(input) || precedesPasswordField(input) ? 'username' : null;
                }
                const contactType = contactFieldType(input);
                if (contactType && (contactType !== 'email' && contactType !== 'tel' || hasContactNeighbours(input))) {
                    return 'contact';
                }
                // A lone username or email box, e.g. the first step of a sign-in.
                if (isUsernameField(input)) return 'username';
                return null;
            }
            // Focus inside an open shadow root reports the host element; the
            // composed path and the shadow roots' active elements lead to the
            // input itself.
            function eventInput(event) {
                const target = event.composedPath ? event.composedPath()[0] : event.target;
                return target instanceof HTMLInputElement ? target : null;
            }
            function innermostActiveElement() {
                let element = document.activeElement;
                while (element && element.shadowRoot && element.shadowRoot.activeElement) {
                    element = element.shadowRoot.activeElement;
                }
                return element;
            }

            function postToNative(name, payload) {
                try {
                    window.webkit.messageHandlers[name].postMessage(payload);
                } catch (e) { /* handler not present (popup, OAuth frame, etc.) — silently ignore */ }
            }

            // The field's rect in the top page's viewport, adding the offset
            // of each same-origin frame around it. A cross-origin frame in
            // the way stops that: the rect is then in its viewport, and
            // frameURL tells native which frame to place it by.
            function rectFor(input) {
                const r = input.getBoundingClientRect();
                const rect = { x: r.left, y: r.top, width: r.width, height: r.height };
                let view = window;
                while (view !== view.top) {
                    const frameElement = view.frameElement; // null across origins
                    if (!frameElement) {
                        rect.frameURL = view.location.href;
                        break;
                    }
                    const frameRect = frameElement.getBoundingClientRect();
                    const style = view.parent.getComputedStyle(frameElement);
                    rect.x += frameRect.left + frameElement.clientLeft + (parseFloat(style.paddingLeft) || 0);
                    rect.y += frameRect.top + frameElement.clientTop + (parseFloat(style.paddingTop) || 0);
                    view = view.parent;
                }
                return rect;
            }
            function fieldPayload(input, kind) {
                const payload = {
                    fieldType: kind,
                    rect: rectFor(input),
                    hasValue: input.value.length > 0
                };
                // Lets the popover say what My Card would fill.
                if (kind === 'contact') {
                    payload.contactTypes = Array.from(new Set(fillableContactFields(input).map((field) => field[1])));
                }
                return payload;
            }

            // One key icon, shown beside whichever detected field has focus.
            // The field is held weakly so a page that removes it can still
            // free it, and the scroll/resize listeners only exist while the
            // icon is visible.
            let keyIcon = null;
            let iconTarget = null; // WeakRef to the focused field while the icon is visible
            let iconLeft = '';
            let iconTop = '';
            let hideTimer = 0;
            let repositioning = false;
            // Kind of each field detected on focus, so the icon click and
            // fillOTP agree with the classification made then.
            const fieldKinds = new WeakMap();

            // The key.fill symbol, drawn from the alpha mask native rendered
            // (cropped to the glyph, so centring the canvas centres the key).
            // Pixels rather than an image URL, which the page's
            // Content-Security-Policy could block.
            function makeKeyGlyph() {
                const canvas = document.createElement('canvas');
                canvas.width = KEY_GLYPH.width;
                canvas.height = KEY_GLYPH.height;
                canvas.style.cssText =
                    'display:block;margin:0;padding:0;border:0;max-width:none;pointer-events:none;' +
                    'width:' + (KEY_GLYPH.width / KEY_GLYPH.scale) + 'px;' +
                    'height:' + (KEY_GLYPH.height / KEY_GLYPH.scale) + 'px;';
                const context = canvas.getContext('2d');
                if (!context) return canvas;
                const image = context.createImageData(KEY_GLYPH.width, KEY_GLYPH.height);
                const alpha = atob(KEY_GLYPH.alpha);
                for (let i = 0; i < alpha.length; i++) {
                    image.data[i * 4] = 128;
                    image.data[i * 4 + 1] = 128;
                    image.data[i * 4 + 2] = 128;
                    image.data[i * 4 + 3] = alpha.charCodeAt(i);
                }
                context.putImageData(image, 0, 0);
                return canvas;
            }

            const ICON_SIZE = 22;
            const ICON_INSET = 6; // from the field's right edge

            function makeIcon() {
                const icon = document.createElement('div');
                icon.style.cssText =
                    'position:absolute;width:' + ICON_SIZE + 'px;height:' + ICON_SIZE + 'px;' +
                    'box-sizing:border-box;margin:0;padding:0;border:0;border-radius:6px;' +
                    'align-items:center;justify-content:center;cursor:default;' +
                    'background:transparent;display:none;z-index:2147483647;pointer-events:auto;';
                if (KEY_GLYPH) icon.appendChild(makeKeyGlyph());
                // A rounded frame while the pointer is over it.
                icon.addEventListener('mouseenter', () => {
                    icon.style.backgroundColor = 'rgba(128, 128, 128, 0.25)';
                });
                icon.addEventListener('mouseleave', () => {
                    icon.style.backgroundColor = 'transparent';
                });

                // Use mousedown so the icon click registers before the input loses focus.
                icon.addEventListener('mousedown', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    const input = currentIconTarget();
                    const kind = input && fieldKinds.get(input);
                    if (kind) postToNative('autofillIconClicked', fieldPayload(input, kind));
                });
                return icon;
            }

            function currentIconTarget() {
                const input = iconTarget && iconTarget.deref();
                return input && input.isConnected ? input : null;
            }

            function positionIcon() {
                const input = currentIconTarget();
                if (!input) {
                    hideIcon();
                    return;
                }
                const r = input.getBoundingClientRect();
                const left = (window.scrollX + r.right - ICON_SIZE - ICON_INSET) + 'px';
                const top  = (window.scrollY + r.top + (r.height - ICON_SIZE) / 2) + 'px';
                // Scrolling the document doesn't move the icon; skip no-op writes.
                if (left !== iconLeft) { keyIcon.style.left = left; iconLeft = left; }
                if (top !== iconTop) { keyIcon.style.top = top; iconTop = top; }
            }

            function setRepositioning(enabled) {
                if (repositioning === enabled) return;
                repositioning = enabled;
                if (enabled) {
                    // Capture phase so scrolling an inner container (its scroll
                    // events don't bubble) moves the icon too.
                    window.addEventListener('scroll', positionIcon, { capture: true, passive: true });
                    window.addEventListener('resize', positionIcon);
                } else {
                    window.removeEventListener('scroll', positionIcon, true);
                    window.removeEventListener('resize', positionIcon);
                }
            }

            function showIcon(input) {
                clearTimeout(hideTimer);
                if (!keyIcon) keyIcon = makeIcon();
                if (!keyIcon.isConnected) document.documentElement.appendChild(keyIcon);
                iconTarget = new WeakRef(input);
                keyIcon.style.display = 'flex';
                setRepositioning(true);
                positionIcon();
            }

            function hideIcon() {
                clearTimeout(hideTimer);
                iconTarget = null;
                if (keyIcon) keyIcon.style.display = 'none';
                setRepositioning(false);
            }

            // Fields are detected as they gain focus instead of by rescanning
            // the document on every DOM mutation: nothing runs while the page
            // mutates or sits in a background tab, and a field whose
            // attributes change after insertion is still recognised. Capture
            // phase because focus and blur don't bubble.
            function fieldFocused(input) {
                const kind = classify(input);
                if (!kind) return;
                fieldKinds.set(input, kind);
                // Native answers with showIcon() when it has something to
                // offer for this kind of field.
                postToNative('autofillFieldFocused', fieldPayload(input, kind));
            }
            document.addEventListener('focus', (event) => {
                const input = eventInput(event);
                if (input) fieldFocused(input);
            }, true);
            // An autofocus field already has focus when this script runs at
            // document end, so no focus event is coming for it. Without
            // document focus, it gets one once the page gains focus.
            const alreadyFocused = innermostActiveElement();
            if (alreadyFocused instanceof HTMLInputElement && document.hasFocus()) {
                fieldFocused(alreadyFocused);
            }
            document.addEventListener('blur', (event) => {
                const input = eventInput(event);
                if (!input || !iconTarget || iconTarget.deref() !== input) return;
                clearTimeout(hideTimer);
                hideTimer = setTimeout(() => {
                    if (innermostActiveElement() !== input && iconTarget && iconTarget.deref() === input) {
                        hideIcon();
                    }
                }, 120);
            }, true);

            // Form submission detection — capture phase so we see it before
            // page scripts can navigate away.
            document.addEventListener('submit', (event) => {
                const form = event.target;
                if (!(form instanceof HTMLFormElement)) return;
                const password = form.querySelector('input[type="password"]');
                if (!password || !password.value) return;
                const username = findRelatedUsername(password);
                postToNative('autofillFormSubmitted', {
                    username: username ? username.value : '',
                    password: password.value
                });
            }, true);

            // React-style frameworks override the value setter on the input
            // prototype; fillField uses the prototype's *original* setter and
            // then dispatches input/change so the framework's state updates.
            function fillField(input, value) {
                const proto = input instanceof HTMLTextAreaElement
                    ? window.HTMLTextAreaElement.prototype
                    : input instanceof HTMLSelectElement
                        ? window.HTMLSelectElement.prototype
                        : window.HTMLInputElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                setter.call(input, value);
                input.dispatchEvent(new Event('input',  { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
            }

            // Picks the option whose value or label matches one of `candidates`
            // (e.g. a country's ISO code or its name).
            function selectOption(select, candidates) {
                const wanted = candidates.filter(Boolean).map((candidate) => candidate.trim().toLowerCase());
                for (const option of select.options) {
                    const value = option.value.trim().toLowerCase();
                    const label = option.textContent.trim().toLowerCase();
                    if (wanted.includes(value) || wanted.includes(label)) {
                        fillField(select, option.value);
                        return;
                    }
                }
            }

            window.__klarAutofill = {
                showIcon: function() {
                    const input = innermostActiveElement();
                    if (input instanceof HTMLInputElement && fieldKinds.has(input)) showIcon(input);
                },
                fillContact: function(values) {
                    // values: the parts of My Card the user agreed to fill,
                    // keyed by autocomplete token
                    const anchor = innermostActiveElement();
                    if (!(anchor instanceof HTMLInputElement) || fieldKinds.get(anchor) !== 'contact') return;
                    if (!isVisibleToUser(anchor)) return;
                    for (const [element, type] of fillableContactFields(anchor)) {
                        // Leave what the user already typed elsewhere in the form.
                        if (element !== anchor && element.value) continue;
                        if (element instanceof HTMLSelectElement) {
                            const candidates = type === 'country' || type === 'country-name'
                                ? [values['country'], values['country-name']]
                                : [values[type]];
                            selectOption(element, candidates);
                            continue;
                        }
                        let value = values[type];
                        if (!value && type === 'tel-national') value = values['tel'];
                        if (!value && type === 'street-address') value = values['address-line1'];
                        if (!value && type === 'name') {
                            value = [values['given-name'], values['family-name']].filter(Boolean).join(' ');
                        }
                        if (value) fillField(element, value);
                    }
                },
                fill: function(payload) {
                    // payload: { username, password }
                    let target = innermostActiveElement();
                    if (!(target instanceof HTMLInputElement)) {
                        target = document.querySelector('input[type="password"]');
                    }
                    if (!target) return;

                    if (isPasswordField(target)) {
                        const username = findRelatedUsername(target);
                        if (username && payload.username) fillField(username, payload.username);
                        if (payload.password) fillField(target, payload.password);
                    } else {
                        if (payload.username) fillField(target, payload.username);
                        const password = findRelatedPassword(target);
                        if (password && payload.password) fillField(password, payload.password);
                    }
                },
                fillOTP: function(payload) {
                    // payload: { code }
                    if (!payload || !payload.code) return;
                    let target = innermostActiveElement();
                    if (!(target instanceof HTMLInputElement) || fieldKinds.get(target) !== 'otp') {
                        target = document.querySelector('input[autocomplete~="one-time-code"]');
                    }
                    if (!target) return;
                    const boxes = digitBoxes(target);
                    if (boxes) {
                        const digits = Array.from(payload.code.replace(/\s/g, ''));
                        boxes.forEach((box, index) => {
                            if (index < digits.length) fillField(box, digits[index]);
                        });
                        return;
                    }
                    fillField(target, payload.code);
                }
            };
        })();
        """#

        let userScript = WKUserScript(
            source: script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(userScript)
    }

    /// The key.fill symbol for the autofill script's key icon, as a JS object
    /// literal: its alpha mask at 3x, cropped to the glyph, or `null` if the
    /// symbol couldn't be drawn.
    private static let autofillKeyGlyph: String = {
        let scale = 3
        guard let symbol = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        else { return "null" }
        let width = Int(ceil(symbol.size.width)) * scale
        let height = Int(ceil(symbol.size.height)) * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ), let pixels = bitmap.bitmapData else { return "null" }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        symbol.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        // Rows run top to bottom, as canvas ImageData expects.
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return "null" }
        // Whole CSS pixels, so the canvas isn't resampled.
        let croppedWidth = (maxX - minX + scale) / scale * scale
        let croppedHeight = (maxY - minY + scale) / scale * scale
        let left = max(0, min(minX - (croppedWidth - (maxX - minX + 1)) / 2, width - croppedWidth))
        let top = max(0, min(minY - (croppedHeight - (maxY - minY + 1)) / 2, height - croppedHeight))

        var mask = [UInt8]()
        mask.reserveCapacity(croppedWidth * croppedHeight)
        for y in top..<(top + croppedHeight) {
            for x in left..<(left + croppedWidth) {
                mask.append(alpha(x, y))
            }
        }
        return "{ width: \(croppedWidth), height: \(croppedHeight), scale: \(scale), " +
            "alpha: '\(Data(mask).base64EncodedString())' }"
    }()

    // Create a WKWebView with standard configuration
    func createWebView(with customConfiguration: WKWebViewConfiguration? = nil) -> WKWebView {
        let configuration = customConfiguration ?? createConfiguration()
        let webView = CustomWKWebView(frame: .zero, configuration: configuration)

        // Apply standard WebView settings
        configureWebView(webView)

        return webView
    }
    
    // Configure a WebView with standard settings
    func configureWebView(_ webView: WKWebView) {
        webView.customUserAgent = Self.safariUserAgent
        // Without web developer tools, no local Safari can attach a remote
        // inspector unless the user opened the inspector (enableDeveloperTools(for:)).
        if Self.showsDeveloperTools {
            webView.isInspectable = true
        }
        webView.allowsLinkPreview = true
        webView.focusRingType = .none
        webView.allowsBackForwardNavigationGestures = true
        
        // Enable zoom/magnification functionality
        webView.allowsMagnification = true
        webView.magnification = 1.0 // Default zoom level
    }
    
    /// Inspect Element in every page's menu and remote inspection from
    /// Safari's Develop menu: Settings › General › Web developer tools, and
    /// always in Debug builds.
    static var showsDeveloperTools: Bool {
        #if DEBUG
        true
        #else
        TOMLSettingsManager.shared.webDeveloperTools
        #endif
    }

    /// Applies the setting to the pages open now, not only to new ones.
    static func developerToolsSettingChanged() {
        let enabled = showsDeveloperTools
        TabWebViewCoordinator.setDeveloperTools(enabled)
        ExtensionManager.shared.updateInspectability()
        WebViewPool.shared.replacePooledWebViews()
    }

    /// Call right before opening the Web Inspector on `webView`; without web
    /// developer tools, developer extras and remote inspection are off until then.
    /// Developer extras is a WKPreferences setting, and the preferences object
    /// is shared by every web view built from the same configuration — the
    /// popups and window.open tabs this page opened, or its opener — so those
    /// get it too. It stays on for the life of those web views.
    static func enableDeveloperTools(for webView: WKWebView) {
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView.isInspectable = true
    }
    
    // Create a configuration with specific autoplay settings
    func createConfiguration(allowAutoplay: Bool, dataStore: WKWebsiteDataStore = .default()) -> WKWebViewConfiguration {
        let configuration = createConfiguration(dataStore: dataStore)
        
        if allowAutoplay {
            configuration.mediaTypesRequiringUserActionForPlayback = []
        } else {
            // Only media with sound waits for a click: a muted video that's
            // part of the page
            // (a background video) still plays. With `.video` too, it never
            // did for the web view's whole life, reloads included.
            configuration.mediaTypesRequiringUserActionForPlayback = [.audio]
        }
        
        return configuration
    }
    
    // Create a WebView with specific autoplay settings
    func createWebView(allowAutoplay: Bool, dataStore: WKWebsiteDataStore = .default()) -> WKWebView {
        let configuration = createConfiguration(allowAutoplay: allowAutoplay, dataStore: dataStore)
        let webView = createWebView(with: configuration)
        return webView
    }

    // Apply user-configured WebKit feature overrides via the private _WKFeature
    // SPI on WKPreferences. Overrides come from FeatureFlagsManager (backed by
    // ~/.config/klar/config.toml [feature_flags]). Resolves the setter through
    // the Obj-C runtime and calls it as a C function pointer so we can pass a
    // primitive BOOL (which `perform(_:with:)` can't). Logs one summary line at
    // error level only if the SPI is gone or any keys were not found — so a
    // WebKit rename/removal or a stale TOML entry surfaces without per-call spam.
    private func applyWebKitFeatureOverrides(on preferences: WKPreferences) {
        let overrides = FeatureFlagsManager.shared.overrides
        guard !overrides.isEmpty else { return }

        var missing: [String] = []
        for (key, enabled) in overrides where !setWebKitFeature(key, enabled: enabled, on: preferences) {
            missing.append(key)
        }

        if !missing.isEmpty {
            logError(.webView, "WebKit features not applied (renamed or removed?): \(missing.joined(separator: ", "))")
        }
    }

    // Settings > Passwords > Offer passkeys. With Web Authentication off,
    // pages don't see PublicKeyCredential, so they don't offer passkeys.
    private func applyPasskeySetting(on preferences: WKPreferences) {
        guard !TOMLSettingsManager.shared.offerPasskeys else { return }
        if !setWebKitFeature("WebAuthenticationEnabled", enabled: false, on: preferences) {
            logError(.webView, "Couldn't turn off Web Authentication; passkeys stay available")
        }
    }

    /// False when the SPI or the feature is missing.
    @discardableResult
    private func setWebKitFeature(_ key: String, enabled: Bool, on preferences: WKPreferences) -> Bool {
        typealias SetEnabledIMP = @convention(c) (NSObject, Selector, Bool, NSObject) -> Void
        let setSel = Selector(("_setEnabled:forFeature:"))

        guard let setterMethod = class_getInstanceMethod(WKPreferences.self, setSel),
              let target = WebKitFeatureRegistry.rawFeature(forKey: key)
        else { return false }
        let setEnabled = unsafeBitCast(method_getImplementation(setterMethod), to: SetEnabledIMP.self)
        setEnabled(preferences, setSel, enabled, target)
        return true
    }
}
