import SwiftUI
import Foundation
import WebKit

// MARK: - WebView Pre-loading System

/// Pre-warmed `WKWebView` pool. Each pre-warmed WebView spawns a Web Content
/// process that holds 30-60 MB resident even when the WebView is unused, so
/// the pool deliberately stays small and gets cleared whenever the app is
/// idle, backgrounded, or about to sleep — otherwise memory grows every time
/// the app activates (notably on lid-open after sleep, where
/// `didBecomeActive` would re-warm the pool on top of any existing entries).
class WebViewPool: ObservableObject {
    static let shared = WebViewPool()

    private var pool: [WKWebView] = []
    private let maxPoolSize = 1

    /// Set by `TabManager` so the pool can avoid pre-warming when the user
    /// has zero tabs (no upcoming "new tab" cost to amortize).
    var tabCountProvider: (() -> Int)?

    private init() {
        setupLifecycleObservers()

        // Start warming up the pool after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.warmUpPoolInternal()
        }
    }

    func getPreWarmedWebView() -> WKWebView? {
        if !pool.isEmpty {
            let webView = pool.removeFirst()

            // Asynchronously refill the pool
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.addWebViewToPool()
            }

            return webView
        }

        return nil
    }

    private func warmUpPoolInternal() {
        // Skip pre-warming when no tabs are open — there's no imminent
        // "new tab" allocation to amortize, and each pool WebView keeps a
        // ~30-60 MB Web Content process alive.
        if let count = tabCountProvider?(), count == 0 {
            return
        }

        while pool.count < maxPoolSize {
            addWebViewToPool()
        }
    }

    /// Public method to allow external warming (e.g. on app activation).
    func warmUpPool() {
        warmUpPoolInternal()
    }

    private func addWebViewToPool() {
        guard pool.count < maxPoolSize else { return }

        let webView = createOptimizedWebView()
        pool.append(webView)
    }

    private func createOptimizedWebView() -> WKWebView {
        // Pool webviews are for new tabs, which may autoplay; tabs coming
        // back from suspension get a fresh WebView without autoplay instead
        // (TabWebViewCoordinator.createWebView).
        return WebViewConfiguration.shared.createWebView(allowAutoplay: true)
    }

    func clearPool() {
        pool.removeAll()
    }

    /// For a setting read as web views are configured: the pooled one, if
    /// any, is made again with it.
    func replacePooledWebViews() {
        guard !pool.isEmpty else { return }
        pool.removeAll()
        addWebViewToPool()
    }

    // MARK: - Lifecycle

    private func setupLifecycleObservers() {
        // Drop pool when the system is about to sleep — the Web Content
        // processes would otherwise sit resident for the entire sleep
        // duration, and the pool gets re-warmed on `didBecomeActive` anyway.
        NSWorkspace.shared.notificationCenter.addMainObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil
        ) { [weak self] _ in
            self?.clearPool()
        }
    }
}
