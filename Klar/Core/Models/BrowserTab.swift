import SwiftUI
import Foundation
import AppKit

class BrowserTab: ObservableObject, Identifiable, Equatable, Codable {
    let id: UUID
    let createdAt: Date
    @Published var url: String
    @Published var title: String
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var favicon: NSImage?
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isPlayingMedia: Bool = false
    @Published var isMediaMuted: Bool = false
    
    // Dynamic background color extracted from website
    @Published var backgroundColor: Color = Color.black
    @Published var extractedHexColor: String = "#000000"
    
    // Track parent tab for new tabs created from links (for back navigation)
    var parentTabId: UUID?

    /// The space the tab was opened in. A saved tab's browser tab follows its
    /// saved tab's space (SpaceManager keeps this in step), so the tab stays
    /// in that space when it becomes a regular tab again. Nil in tabs from
    /// before spaces: those are in the first space.
    var spaceID: UUID?

    /// Opened by its parent tab's script (window.open): its page can reach
    /// the parent's through window.opener, so the parent mustn't be
    /// suspended while this tab is live.
    var hasOpener = false

    /// The open tab this is the window's page of (`OpenTabStore`): a regular
    /// tab is in every window, each with a page of its own.
    var openTabID: UUID?

    /// Counts the page's own navigations, each of which takes its open tab
    /// along (`OpenTabStore`): not a redirect, nor an address the page
    /// rewrote, nor the load of an address its open tab went to elsewhere.
    @Published private(set) var ownNavigationCount = 0
    /// Loading where its open tab went elsewhere (`follow`)
    private var isFollowingOpenTab = false

    /// A private tab: its pages' website data is kept in memory only, shared
    /// with the other private tabs until the last one closes, and its visits
    /// stay out of history. Not persisted, so it isn't restored at launch.
    /// It never changes: a page moves in or out of private browsing in a new
    /// tab (TabManager.reopenTab), since a web view's data store can't.
    let isPrivate: Bool

    // Track when this tab was last active for persistent activity tracking
    var lastActiveAt: Date
    
    // Track when URL is explicitly changed by user vs automatically updated by WebView
    private(set) var pendingUserNavigation: Bool = false
    
    // Track if tab has loaded content (including error pages)
    @Published var hasLoadedContent: Bool = false
    
    // Track if tab is currently showing an error page
    @Published var isShowingErrorPage: Bool = false
    
    // Per-tab Find state persistence
    var findState: FindState?

    /// True while the tab is meant to be without a web view: tabs restored
    /// at launch, and background tabs suspended to free memory (see
    /// TabSuspensionManager). BrowserView builds web views only for tabs
    /// that aren't suspended, plus the active one, whose new web view
    /// resumes it. Not published: TabManager publishes the change.
    private(set) var isSuspended = false

    /// Loaded without being shown, like a pinned site at launch: its page
    /// wasn't opened by the user just now, so it doesn't autoplay sound.
    var isLoadedInBackground = false

    /// What the tab's last web view showed — back/forward list, scroll
    /// position, form data — and its zoom, for the next one to restore.
    private(set) var suspendedInteractionState: Any?
    private(set) var suspendedPageZoom: CGFloat?

    // Coding keys for persistence (include lastActiveAt for session persistence)
    enum CodingKeys: String, CodingKey {
        case id, createdAt, url, title, lastActiveAt, spaceID, openTabID
    }
    
    init(id: UUID = UUID(), url: String = "", title: String = "New Tab", parentTabId: UUID? = nil, isPrivate: Bool = false) {
        self.id = id
        self.isPrivate = isPrivate
        self.createdAt = Date()
        self.url = url
        self.title = title
        self.parentTabId = parentTabId
        self.lastActiveAt = Date()
        self.favicon = nil
        self.pendingUserNavigation = false
        self.hasLoadedContent = false
        self.isPlayingMedia = false
        self.isMediaMuted = false
        self.findState = nil
    }
    
    // Special initializer for restoring tabs with existing ID (used by EnhancedSidebarManager)
    init(id: UUID, createdAt: Date, url: String, title: String, lastActiveAt: Date = Date()) {
        self.id = id
        self.isPrivate = false
        self.createdAt = createdAt
        self.url = url
        self.title = title
        self.parentTabId = nil // Restored tabs don't have parent relationships
        self.lastActiveAt = lastActiveAt
        self.favicon = nil
        self.pendingUserNavigation = false
        self.hasLoadedContent = !url.isEmpty && url != "about:blank"
        self.isPlayingMedia = false
        self.isMediaMuted = false
        self.findState = nil
    }
    
    // Computed property to check if tab is in empty state
    var isEmpty: Bool {
        return !hasLoadedContent && (url.isEmpty || url == "about:blank")
    }
    
    // MARK: - Codable Implementation
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.isPrivate = false
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.url = try container.decode(String.self, forKey: .url)
        self.title = try container.decode(String.self, forKey: .title)
        // Handle backwards compatibility for tabs that don't have lastActiveAt
        self.lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? Date()
        self.spaceID = try container.decodeIfPresent(UUID.self, forKey: .spaceID)
        self.openTabID = try container.decodeIfPresent(UUID.self, forKey: .openTabID)
        self.parentTabId = nil // Don't persist parent relationships across app restarts
        self.isLoading = false
        self.favicon = nil
        self.pendingUserNavigation = false
        self.hasLoadedContent = !url.isEmpty && url != "about:blank"
        self.isPlayingMedia = false
        self.isMediaMuted = false
        self.findState = nil
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        // Save clean URL without tracking parameters
        let result = URLUtilities.removeTrackingParameters(from: url)
        try container.encode(result.cleanURL, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(lastActiveAt, forKey: .lastActiveAt)
        try container.encodeIfPresent(spaceID, forKey: .spaceID)
        try container.encodeIfPresent(openTabID, forKey: .openTabID)
    }
    
    // Call this when user explicitly navigates to a new URL
    func navigateToURL(_ newURL: String) {
        isFollowingOpenTab = false
        // Clear loading state when starting new navigation
        self.isLoading = false
        self.estimatedProgress = 0.0
        self.hasLoadedContent = false
        self.pendingUserNavigation = true
        self.url = newURL
        self.lastActiveAt = Date()
    }
    
    // Call this when WebView automatically updates the URL (during navigation within the page)
    func updateURLFromWebView(_ newURL: String) {
        self.pendingUserNavigation = false
        self.url = newURL
    }
    
    /// Its open tab went on to `newURL` in another window or on another Mac
    /// (`OpenTabStore`): the page goes there too, now if it's on screen,
    /// else when it's shown next rather than picking up where its last web
    /// view left off. That load isn't one of its own navigations.
    func follow(url newURL: String, title newTitle: String) {
        pendingUserNavigation = true
        isFollowingOpenTab = true
        url = newURL
        title = newTitle
    }

    /// A navigation committed in its page, or the page went to a new entry
    /// of its history without a load (pushState, back or forward within it)
    func didNavigate() {
        if isFollowingOpenTab {
            isFollowingOpenTab = false
        } else {
            ownNavigationCount += 1
        }
    }

    // Call this when WebView starts loading the pending navigation
    func clearPendingNavigation() {
        self.pendingUserNavigation = false
    }
    
    // Call this when the tab becomes active to update activity tracking
    func markAsActive() {
        self.lastActiveAt = Date()
    }

    /// Marks the tab as having no web view. `interactionState` and
    /// `pageZoom` are what its last web view showed, when there was one to ask.
    func markSuspended(interactionState: Any? = nil, pageZoom: CGFloat? = nil) {
        isSuspended = true
        if let interactionState {
            suspendedInteractionState = interactionState
        }
        if let pageZoom {
            suspendedPageZoom = pageZoom
        }
    }

    /// Called once the tab has a web view again. Returns what to restore, if
    /// the previous web view left anything.
    func resume() -> (interactionState: Any?, pageZoom: CGFloat?) {
        isSuspended = false
        defer {
            suspendedInteractionState = nil
            suspendedPageZoom = nil
        }
        return (suspendedInteractionState, suspendedPageZoom)
    }

    static func == (lhs: BrowserTab, rhs: BrowserTab) -> Bool {
        return lhs.id == rhs.id
    }
} 