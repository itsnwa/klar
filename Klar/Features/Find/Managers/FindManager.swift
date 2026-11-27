import SwiftUI
import WebKit
import Combine

/// Find in page, on WebKit's own find machinery, its private find SPI.
/// WebKit selects and scrolls to each match and draws the
/// overlay and yellow indicator itself, so nothing is injected into the
/// page or changed in its DOM. Should the SPI go missing, the public
/// `WKWebView.find` still selects and scrolls to matches, uncounted.
class FindManager: ObservableObject {
    @Published var findState = FindState()
    @Published private(set) var passageFind: PassageFind?

    /// Mirrors the panel's @FocusState so non-view code (keyboard shortcuts,
    /// menu actions) can decide whether Cmd+F should focus or close the panel.
    @Published var isInputFocused: Bool = false

    /// Bumped to ask the panel to grab focus without changing visibility.
    @Published var focusRequest: UUID? = nil

    weak var tabManager: TabManager? {
        didSet { observeActiveTab() }
    }
    private var searchDebounceTask: Task<Void, Never>?
    private let searchDebounceDelay: TimeInterval = 0.15

    /// Most matches WebKit is asked to count; past it the panel shows "1000+"
    /// and WebKit leaves out the overlay.
    private static let matchLimit = 1000

    // Track current tab ID to manage per-tab states
    private var currentTabId: UUID?

    private var cancellables = Set<AnyCancellable>()
    private var activeTabLoadingCancellable: AnyCancellable?

    /// The page showing WebKit's find UI (overlay and indicator), if any.
    /// Only ever the active tab's, as it's hidden when the tab is left, so
    /// clearing never reaches into another page.
    private weak var findUIWebView: WKWebView?

    /// The new query whose first answer is on its way. That answer is
    /// match 1; answers after it are steps from there.
    private var pendingSearchQuery: String?

    /// Bumped per search, so a stale timeout can't end a newer search.
    private var searchGeneration = 0

    private struct PassageRequest {
        let id = UUID()
        let quote: String
        /// Nil while reading the page for a looser match.
        var query: String?
        var alternateQuery: String?
        var didReadPage = false
    }

    private var passageRequest: PassageRequest?

    /// The last query nothing on this page matched. A query that contains
    /// it can't match either, so typing on keeps Ask AI up without searching
    /// again. Forgotten when the page loads another document, the tab
    /// changes or the panel closes; ⌘G still searches.
    private var missedQuery: String?

    /// The answer being written, if any: cancelled by Stop, a new question,
    /// closing the panel, and leaving or closing the tab.
    private var answerTask: Task<Void, Never>?

    /// Receives WebKit's find answers; WebKit only holds it weakly.
    private lazy var findDelegate: WebKitFindDelegate = WebKitFindDelegate(manager: self)

    /// Web views already given `findDelegate`.
    private let webViewsWithFindDelegate = NSHashTable<WKWebView>.weakObjects()

    private var hasLoggedFindFallback = false

    init(tabManager: TabManager? = nil) {
        self.tabManager = tabManager
        observeActiveTab()
    }

    private func observeActiveTab() {
        cancellables.removeAll()
        guard let tabManager = tabManager else { return }
        currentTabId = tabManager.activeTabId
        observeLoading(of: tabManager.activeTab)

        tabManager.$activeTabId
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Already on main thread via receive(on:), so we can hop into
                // the MainActor isolation domain synchronously.
                self?.handleTabChange()
            }
            .store(in: &cancellables)
    }

    /// Watches the active tab for a new document starting to load.
    private func observeLoading(of tab: BrowserTab?) {
        activeTabLoadingCancellable = tab?.$isLoading
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.activePageWillChange()
            }
    }

    // MARK: - Tab Change Handling

    @MainActor
    private func handleTabChange() {
        guard let tabManager = tabManager else { return }

        // Save current Find state to the previous tab if it exists
        if let currentId = currentTabId,
           let previousTab = tabManager.tabs.first(where: { $0.id == currentId }) {
            saveCurrentStateToTab(previousTab)
        }

        // Searches and answers still pending were for the page being left, and
        // so is its find UI, whose yellow indicator (a window of its own) would
        // otherwise float over the next tab. Nothing runs in the new page.
        cancelPendingSearch()
        cancelPassageFind()
        hideFindUI()
        missedQuery = nil

        // So is an answer still coming; what came of it stays in its chat
        // (saved above, marked stopped)
        answerTask?.cancel()
        answerTask = nil

        observeLoading(of: tabManager.activeTab)

        // Update to new active tab
        guard let newActiveTab = tabManager.activeTab else {
            // No active tab, hide Find panel
            findState.isVisible = false
            currentTabId = nil
            return
        }

        // Load Find state for new active tab
        currentTabId = newActiveTab.id
        loadStateFromTab(newActiveTab)
    }

    @MainActor
    private func saveCurrentStateToTab(_ tab: BrowserTab) {
        // Nothing worth restoring: drop any older snapshot as well, or the tab
        // would come back with a panel the user has since closed.
        guard findState.isVisible || !findState.searchText.isEmpty || !findState.chatMessages.isEmpty else {
            tab.findState = nil
            return
        }

        // Sanitize: a tab that's no longer active won't receive further AI
        // stream chunks or find answers. Stopping an answer and freezing
        // isSearching here prevents restored tabs from showing a stuck typing
        // indicator or spinner.
        var snapshot = findState
        snapshot.isSearching = false
        if searchDebounceTask != nil || pendingSearchQuery != nil {
            // The result shown is an older query's. An unknown count keeps the
            // arrows up (an empty one would offer "Ask AI" instead), and Enter
            // then searches afresh.
            snapshot.findResult = FindResult(count: .unknown)
        }
        for index in snapshot.chatMessages.indices where snapshot.chatMessages[index].isStreaming {
            snapshot.chatMessages[index].stop()
        }
        tab.findState = snapshot
    }

    @MainActor
    private func loadStateFromTab(_ tab: BrowserTab) {
        // Restores the panel only. Nothing runs in the page, so its selection
        // and scroll position stay as they were; the restored count's
        // highlights come back with the next find step.
        let restored = tab.findState ?? FindState()
        updateFindState { $0 = restored }
    }

    // MARK: - Public Interface

    @MainActor
    func showFind() {
        guard let tabManager = tabManager,
              let activeTab = tabManager.activeTab,
              activeTab.hasLoadedContent else {
            // Don't show Find panel if no content is loaded
            return
        }

        // Update current tab tracking
        currentTabId = activeTab.id

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            updateFindState {
                $0.isVisible = true
                $0.mode = .search
            }
        }

        // If there's existing search text, perform the search immediately
        if !findState.searchText.isEmpty {
            performSearch(findState.searchText)
        }

        // Focus will be handled by the view with a small delay to avoid race conditions
    }

    @MainActor
    func hideFind() {
        // Cancel any pending search and take WebKit's find UI down. The last
        // match stays selected.
        cancelPendingSearch()
        cancelPassageFind()
        hideFindUI()
        missedQuery = nil
        stopAnswer()

        // Typing goes back to the page, if it was going into the panel
        if isInputFocused {
            tabManager?.focusActiveWebView()
        }
        isInputFocused = false

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            updateFindState {
                $0.isVisible = false
                // Showing the panel again searches afresh
                $0.isSearching = false
                $0.findResult = FindResult()
            }
        }
    }
    
    /// Smart Cmd+F handling: open & focus when hidden; just focus when open
    /// but the input has lost focus; close when open and already focused.
    @MainActor
    func handleFindShortcut() {
        if findState.isVisible {
            if isInputFocused {
                hideFind()
            } else {
                focusRequest = UUID()
            }
        } else {
            showFind()
        }
    }

    @MainActor
    func toggleFind() {
        if findState.isVisible {
            hideFind()
        } else {
            showFind()
        }
    }
    
    @MainActor
    func updateSearchText(_ text: String) {
        guard text != findState.searchText else { return }

        // Debounce search to avoid excessive WebKit calls
        searchDebounceTask?.cancel()
        searchDebounceTask = nil

        // Only perform search if Find panel is visible
        guard findState.isVisible else {
            findState.searchText = text
            return
        }

        if text.isEmpty {
            clearSearch()
            return
        }

        // More of a query the page doesn't have: Ask AI stays, without a search
        if let missedQuery, text.range(of: missedQuery, options: .caseInsensitive) != nil {
            cancelPendingSearch()
            updateFindState {
                $0.searchText = text
                $0.isSearching = false
                $0.findResult = FindResult()
            }
            return
        }

        updateFindState {
            $0.searchText = text
            // A spinner rather than "No results" until the search answers; the
            // previous query's matches stay up meanwhile.
            $0.isSearching = true
        }
        searchDebounceTask = Task { [weak self, delay = searchDebounceDelay] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.performSearch(text)
        }
    }

    @MainActor
    func findNext() {
        navigate(backwards: false)
    }

    @MainActor
    func findPrevious() {
        navigate(backwards: true)
    }
    
    /// The sparkle button opens the composer. Ask AI after a miss submits
    /// the query as the first question, as Return does.
    func switchToAIChat(submitSearch: Bool = false) {
        let question = findState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldAsk = submitSearch && !question.isEmpty
        let wasSearching = findState.isSearching
        cancelPendingSearch()
        hideFindUI()
        if shouldAsk {
            stopAnswer()
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            updateFindState { state in
                state.mode = .chat
                state.isSearching = false
                if wasSearching {
                    state.findResult = FindResult(count: .unknown)
                }
                if shouldAsk {
                    state.chatMessages = []
                } else if state.chatInputText.isEmpty {
                    state.chatInputText = question
                }
            }
        }
        focusRequest = UUID()
        if shouldAsk {
            ask(question)
        }
    }

    func switchToSearch() {
        cancelPassageFind()
        hideFindUI()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            findState.mode = .search
        }
    }

    func sendChatMessage(_ message: String) {
        let question = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // One answer at a time: Stop comes first
        guard !question.isEmpty, !findState.isAnswering else { return }
        findState.chatInputText = ""
        ask(question)
    }

    // MARK: - Searching

    /// Searches the active tab's page for a new query. WebKit starts from the
    /// page's selection, so typing refines the match in place and searching
    /// the same query again moves on to the next one.
    @MainActor
    private func performSearch(_ query: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil

        guard !query.isEmpty, let webView = activeWebView() else {
            pendingSearchQuery = nil
            updateFindState {
                $0.isSearching = false
                $0.findResult = FindResult()
            }
            return
        }

        pendingSearchQuery = query
        updateFindState { $0.isSearching = true }
        find(query, in: webView, backwards: false)
        scheduleSearchTimeout()
    }

    @MainActor
    private func navigate(backwards: Bool) {
        let query = findState.searchText
        guard findState.isVisible, findState.mode == .search, !query.isEmpty else { return }

        // The query's first answer is still on its way; a step taken now would
        // land before the count starts.
        guard pendingSearchQuery != query else { return }

        // A query still in its debounce, or one that found nothing last time
        // (the page may have changed since), gets a fresh search instead.
        guard searchDebounceTask == nil, findState.findResult.hasResults else {
            performSearch(query)
            return
        }
        guard let webView = activeWebView() else { return }

        // Step the counter now; WebKit's answer brings the count up to date.
        if case .exact(let total) = findState.findResult.count {
            let current = min(max(findState.findResult.currentResult, 1), total)
            updateFindState {
                $0.findResult.currentResult = backwards
                    ? (current == 1 ? total : current - 1)
                    : (current == total ? 1 : current + 1)
            }
        }
        find(query, in: webView, backwards: backwards)
    }

    /// One find step in `webView`: from the page's selection to the next match,
    /// or the previous one, wrapping around at the ends. WebKit selects the
    /// match, scrolls to it and answers through `findDelegate`.
    @MainActor
    private func find(_ query: String, in webView: WKWebView, backwards: Bool) {
        guard WebKitFind.isAvailable else {
            findWithPublicAPI(query, in: webView, backwards: backwards)
            return
        }

        if !webViewsWithFindDelegate.contains(webView) {
            // Once per web view: `_setFindDelegate:` crashes on WebKit's own
            // assertion if the page's find client has been swapped out since
            // (WebKit's NSTextFinder support does that), so it's not repeated.
            WebKitFind.setFindDelegate(findDelegate, on: webView)
            webViewsWithFindDelegate.add(webView)
        }
        if findUIWebView !== webView {
            hideFindUI()
            findUIWebView = webView
        }

        var options: WebKitFind.Options = [.caseInsensitive, .wrapAround, .showOverlay, .showFindIndicator]
        if backwards {
            options.insert(.backwards)
        }
        WebKitFind.findString(query, options: options, maxCount: Self.matchLimit, in: webView)
    }

    /// Fallback should WebKit's find SPI go missing: selects and scrolls to a
    /// match, but neither counts nor highlights.
    @MainActor
    private func findWithPublicAPI(_ query: String, in webView: WKWebView, backwards: Bool) {
        if !hasLoggedFindFallback {
            hasLoggedFindFallback = true
            logWarning(.webView, "WebKit find SPI unavailable; Find falls back to WKWebView.find, without match counts")
        }

        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        webView.find(query, configuration: configuration) { [weak self, weak webView] result in
            guard let self, let webView else { return }
            if result.matchFound {
                self.didFind(query, matchCount: nil, in: webView)
            } else {
                self.didFailToFind(query, in: webView)
            }
        }
    }

    /// WebKit answers every find unless the page's web content process went
    /// away meanwhile; don't leave the panel spinning then.
    private func scheduleSearchTimeout() {
        searchGeneration &+= 1
        let generation = searchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.searchGeneration == generation, self.pendingSearchQuery != nil else { return }
            logDebug(.webView, "Find got no answer from WebKit")
            self.pendingSearchQuery = nil
            self.updateFindState {
                $0.isSearching = false
                $0.findResult = FindResult()
            }
        }
    }

    /// Drops a debounced search and any answer still on its way.
    private func cancelPendingSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        pendingSearchQuery = nil
        searchGeneration &+= 1
    }

    @MainActor
    private func clearSearch() {
        cancelPendingSearch()
        updateFindState {
            $0.searchText = ""
            $0.findResult = FindResult()
            $0.isSearching = false
        }
        hideFindUI()
    }

    // MARK: - WebKit Find Answers

    /// A find step landed on a match. `matchCount` is nil from the public-API
    /// fallback, which doesn't count.
    fileprivate func didFind(_ query: String, matchCount: Int?, in webView: WKWebView) {
        if isCurrentPassageFind(query, in: webView) {
            cancelPassageFind()
            return
        }
        guard isCurrentFind(query, in: webView) else {
            hideFindUIIfAbandoned(in: webView)
            return
        }

        let count: FindResult.Count
        if let matchCount, matchCount > Self.matchLimit {
            // WebKit's "more than maxCount" answer
            count = .atLeast(Self.matchLimit)
        } else if let matchCount, matchCount > 0 {
            count = .exact(matchCount)
        } else {
            count = .unknown
        }

        let isFirstAnswer = pendingSearchQuery == query
        pendingSearchQuery = nil
        updateFindState { state in
            if case .exact(let total) = count {
                // A new query starts at match 1; a step keeps the position
                // navigate(backwards:) moved to, within the new total.
                state.findResult.currentResult = isFirstAnswer ? 1 : min(max(state.findResult.currentResult, 1), total)
            } else {
                state.findResult.currentResult = 0
            }
            state.findResult.count = count
            state.isSearching = false
        }
    }

    fileprivate func didFailToFind(_ query: String, in webView: WKWebView) {
        if isCurrentPassageFind(query, in: webView) {
            retryPassageFind(in: webView)
            return
        }
        guard isCurrentFind(query, in: webView) else {
            hideFindUIIfAbandoned(in: webView)
            return
        }

        pendingSearchQuery = nil
        missedQuery = query
        updateFindState {
            $0.isSearching = false
            $0.findResult = FindResult()
        }
    }

    /// A find sent just before its page's find UI was hidden (Find closed,
    /// or the tab left) can still put the overlay up afterwards; take it down
    /// again. A page still showing find UI is waiting on a newer query.
    private func hideFindUIIfAbandoned(in webView: WKWebView) {
        guard webView !== findUIWebView else { return }
        WebKitFind.hideFindUI(in: webView)
    }

    /// Whether a find answer is for what the panel shows: the current query in
    /// the active tab's page. Answers for a tab since left, or for a query
    /// since edited, are dropped.
    private func isCurrentFind(_ query: String, in webView: WKWebView) -> Bool {
        findState.isVisible && findState.mode == .search && query == findState.searchText && webView === activeWebView()
    }

    // MARK: - Show on Page

    func showPassage(inMessage messageID: UUID, blockID: Int) {
        guard findState.isVisible, findState.mode == .chat,
              let tab = tabManager?.activeTab, tab.id == currentTabId,
              let message = findState.chatMessages.first(where: { $0.id == messageID }),
              message.hasPageContent, !message.isStreaming,
              let pageURL = message.pageURL,
              let block = message.document.blocks.first(where: { $0.id == blockID }),
              case .quote(let text) = block.kind else { return }

        // Keep the search field and its results intact while using WebKit's
        // selection, scroll position, overlay and indicator for the quote.
        cancelPassageFind()
        hideFindUI()
        var passage = PassageFind(messageID: messageID, blockID: blockID)
        guard let webView = activeWebView(),
              let currentURL = webView.url ?? URL(string: tab.url),
              MarkdownDocument.pageKey(of: currentURL) == MarkdownDocument.pageKey(of: pageURL) else {
            passage.status = .differentPage
            passageFind = passage
            return
        }

        let quote = Self.collapsingWhitespace(in: String(MarkdownInline.parse(text).characters))
        guard !quote.isEmpty else {
            passage.status = .notFound
            passageFind = passage
            return
        }

        let request = PassageRequest(quote: quote, query: quote)
        let requestID = request.id
        passageFind = passage
        passageRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.passageRequest?.id == requestID else { return }
            self.failPassageFind()
        }
        find(quote, in: webView, backwards: false)
    }

    private func isCurrentPassageFind(_ query: String, in webView: WKWebView) -> Bool {
        passageRequest?.query == query && findState.isVisible && findState.mode == .chat
            && currentTabId == tabManager?.activeTabId && webView === activeWebView()
    }

    private func retryPassageFind(in webView: WKWebView) {
        guard var request = passageRequest else { return }
        if let alternate = request.alternateQuery {
            request.query = alternate
            request.alternateQuery = nil
            passageRequest = request
            find(alternate, in: webView, backwards: false)
            return
        }
        guard !request.didReadPage, request.quote.utf16.count <= 500 else {
            failPassageFind()
            return
        }

        request.didReadPage = true
        request.query = nil
        passageRequest = request
        let requestID = request.id
        let quote = request.quote
        Task { [weak self, weak webView] in
            guard let webView else { return }
            let result = try? await webView.callAsyncJavaScript(
                Self.passageTextScript, arguments: ["quote": quote], contentWorld: .defaultClient
            )
            guard let self, var request = self.passageRequest, request.id == requestID,
                  webView === self.activeWebView() else { return }
            guard let spelling = result as? String, !spelling.isEmpty else {
                self.failPassageFind()
                return
            }

            let collapsed = Self.collapsingWhitespace(in: spelling)
            let candidates = spelling == collapsed ? [spelling] : [collapsed, spelling]
            let retries = candidates.filter { $0 != quote }
            guard let query = retries.first else {
                self.failPassageFind()
                return
            }
            request.query = query
            request.alternateQuery = retries.dropFirst().first
            self.passageRequest = request
            self.find(query, in: webView, backwards: false)
        }
    }

    private func cancelPassageFind() {
        passageRequest = nil
        if passageFind != nil {
            passageFind = nil
        }
    }

    private func failPassageFind() {
        passageRequest = nil
        hideFindUI()
        passageFind?.status = .notFound
    }

    private static func collapsingWhitespace(in text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Recover the page's spelling for a contiguous quote. Treat curly and
    /// straight quotes, and runs of whitespace, as equivalent. WebKit still
    /// does the actual finding. The model's text is passed as data and each
    /// literal is escaped before building the expression.
    private static let passageTextScript = #"""
        const pattern = Array.from(quote, (character) => {
            if (/\s/u.test(character)) return '\\s+';
            if (/['‘’]/u.test(character)) return "['‘’]";
            if (/["“”]/u.test(character)) return '["“”]';
            return character.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        }).join('');
        const visibleText = document.body?.innerText?.slice(0, 1_000_000) ?? '';
        const original = quote.toLowerCase();
        for (const [spelling] of visibleText.matchAll(new RegExp(pattern, 'giu'))) {
            if (spelling.toLowerCase() !== original) return spelling;
        }
        return null;
        """#

    // MARK: - Find UI

    /// Takes WebKit's find UI (overlay and indicator) down in the page showing
    /// it. The selection, the last match, stays.
    @MainActor
    private func hideFindUI() {
        guard let webView = findUIWebView else { return }
        findUIWebView = nil
        WebKitFind.hideFindUI(in: webView)
    }

    /// The active tab started loading another document; the find UI and the
    /// count belong to the one it replaces.
    @MainActor
    private func activePageWillChange() {
        cancelPassageFind()
        hideFindUI()
        missedQuery = nil
        guard findState.findResult.hasResults else { return }
        // Arrows without a count, until the next step searches the new page
        updateFindState { $0.findResult = FindResult(count: .unknown) }
    }

    /// Applies changes as a single publish, and none for a no-op: each one
    /// re-renders the panel.
    private func updateFindState(_ update: (inout FindState) -> Void) {
        var state = findState
        update(&state)
        if state != findState {
            findState = state
        }
    }

    private func activeWebView() -> WKWebView? {
        guard let tabManager = tabManager,
              let activeTabId = tabManager.activeTabId else { return nil }
        // Nil while the tab has no web view yet (just created, or coming back
        // from suspension)
        return tabManager.getWebViewForTab(activeTabId)
    }
    
    // MARK: - AI Integration

    /// Asks the provider in Settings › AI about the page, with the chat so
    /// far, and writes the answer into the chat as it comes.
    private func ask(_ question: String) {
        guard let tab = tabManager?.activeTab else { return }
        answerTask?.cancel()
        let history = conversation()
        let webView = activeWebView()
        let answer = ChatMessage.answer(about: webView?.url ?? URL(string: tab.url))
        findState.chatMessages.append(.question(question))
        findState.chatMessages.append(answer)
        answerTask = Task { [weak self, weak webView] in
            await self?.writeAnswer(answer, to: question, history: history, inTab: tab.id, webView: webView)
        }
    }

    private func writeAnswer(_ answer: ChatMessage, to question: String, history: [AIPrompt.Turn], inTab tabID: UUID, webView: WKWebView?) async {
        // Each write first checks the answer is still wanted, where it was
        // asked: Stop, a new question, closing the panel or leaving the tab
        // cancel it, and by the time an await returns the panel may show
        // another tab's chat.
        func update(_ change: (inout ChatMessage) -> Void) -> Bool {
            guard !Task.isCancelled, currentTabId == tabID, tabManager?.activeTabId == tabID,
                  let index = findState.chatMessages.firstIndex(where: { $0.id == answer.id }) else { return false }
            change(&findState.chatMessages[index])
            return true
        }

        // A local model's context is small; Claude's and Codex's take much more of the page
        let provider = await AIProvider.resolved()
        guard update({ $0.provider = provider }) else { return }
        let page = await extractWebpageContent(from: webView, at: answer.pageURL, limit: provider == .ollama ? 8_000 : 40_000)
        guard update({ $0.hasPageContent = page != nil }) else { return }
        do {
            let stream = try await AIAssistant.answer(question, webpageContent: page, history: history, provider: provider)
            for try await piece in stream {
                guard update({ $0.append(piece) }) else { return }
            }
            _ = update { $0.finish() }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            _ = update { $0.fail(reason) }
        }
        if !Task.isCancelled {
            answerTask = nil
        }
    }

    /// Stops the answer coming, keeping what came so far
    func stopAnswer() {
        answerTask?.cancel()
        answerTask = nil
        updateFindState { state in
            for index in state.chatMessages.indices where state.chatMessages[index].isStreaming {
                state.chatMessages[index].stop()
            }
        }
    }

    /// Asks the question before an answer again, in its place
    func retryAnswer(_ messageID: UUID) {
        guard !findState.isAnswering,
              let index = findState.chatMessages.firstIndex(where: { $0.id == messageID }), index > 0,
              findState.chatMessages[index - 1].isUser else { return }
        if passageFind?.messageID == messageID {
            cancelPassageFind()
            hideFindUI()
        }
        let question = findState.chatMessages[index - 1].content
        findState.chatMessages.removeSubrange((index - 1)...)
        ask(question)
    }

    /// The chat so far, for a follow-up: the last few turns, long answers
    /// shortened, failed ones left out
    private func conversation() -> [AIPrompt.Turn] {
        let turns = findState.chatMessages.compactMap { message -> AIPrompt.Turn? in
            if message.isUser {
                return AIPrompt.Turn(isUser: true, text: message.content)
            }
            guard !message.isStreaming, !message.content.isEmpty else { return nil }
            if case .failed = message.outcome {
                return nil
            }
            let text = message.content.count > 2_000 ? String(message.content.prefix(2_000)) + "…" : message.content
            return AIPrompt.Turn(isUser: false, text: text)
        }
        return Array(turns.suffix(8))
    }

    /// Opens a link from an answer in a new tab (in the background when
    /// asked), private from a private tab. A relative one is relative to the
    /// page.
    func openLink(_ url: URL, inBackground: Bool) {
        guard let tabManager, let tab = tabManager.activeTab else { return }
        let address = url.scheme == nil ? URL(string: url.relativeString, relativeTo: URL(string: tab.url))?.absoluteURL : url
        guard let address, let scheme = address.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        tabManager.createNewTab(url: address.absoluteString, parentTabId: tab.id, activate: !inBackground)
    }

    /// Fetches what a link card shows as it's about to show (never sooner:
    /// the address is the model's), and keeps it with its answer.
    func loadLinkPreview(for url: URL, inMessage messageID: UUID) async {
        guard let message = findState.chatMessages.first(where: { $0.id == messageID }),
              message.linkPreviews[url] == nil else { return }
        // A private tab's icon is only kept in memory
        let isPrivate = tabManager?.activeTab?.isPrivate ?? true
        async let content = LinkPreviews.content(for: url)
        let icon = await FaviconCacheManager.shared.getFavicon(for: url.absoluteString, persist: !isPrivate)
        let fetched = await content
        guard !Task.isCancelled, let index = findState.chatMessages.firstIndex(where: { $0.id == messageID }) else { return }
        findState.chatMessages[index].linkPreviews[url] = LinkPreview(
            title: fetched?.title,
            summary: fetched?.summary,
            siteName: fetched?.siteName,
            image: fetched?.image.map { NSImage(cgImage: $0.image, size: .zero) },
            icon: icon
        )
    }

    /// The page for the AI: its readable text as light Markdown (headings,
    /// lists, table rows), links as `[text](address)` so an answer can link
    /// to what's on the page instead of making addresses up, and what's
    /// selected. Read in Klar's own content world, out of the page's
    /// scripts' reach. Up to `limit` characters.
    @MainActor
    private func extractWebpageContent(from webView: WKWebView?, at pageURL: URL?, limit: Int) async -> String? {
        guard let webView, webView === activeWebView() else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(Self.pageTextScript, arguments: ["limit": limit], contentWorld: .defaultClient)
            guard let page = result as? [String: Any], let content = page["content"] as? String else { return nil }
            let address = page["url"] as? String
            if let pageURL, let address, let extractedURL = URL(string: address),
               MarkdownDocument.pageKey(of: extractedURL) != MarkdownDocument.pageKey(of: pageURL) {
                return nil
            }
            var lines: [String] = []
            if let title = page["title"] as? String, !title.isEmpty {
                lines.append("Title: \(title)")
            }
            if let address, !address.isEmpty {
                lines.append("Address: \(address)")
            }
            if let description = page["description"] as? String, !description.isEmpty {
                lines.append("Description: \(description)")
            }
            if let selection = page["selection"] as? String, !selection.isEmpty {
                lines.append("Selected on the page: \(selection)")
            }
            lines.append("")
            lines.append(content)
            return lines.joined(separator: "\n")
        } catch {
            logDebug(.webView, "Couldn't read the page for the AI: \(error.localizedDescription)")
            return nil
        }
    }

    /// The body of `extractWebpageContent`'s function, given `limit`. The
    /// page's main part when it marks one (main, a single article), else the
    /// whole page without its navigation, banner and footer; hidden
    /// elements, scripts, images and form controls left out.
    private static let pageTextScript = """
        const skipped = new Set(['script', 'style', 'noscript', 'template', 'svg', 'canvas', 'iframe', 'object', 'embed',
            'video', 'audio', 'img', 'picture', 'math', 'select', 'textarea', 'input', 'button']);
        const blocks = new Set(['address', 'article', 'aside', 'blockquote', 'dd', 'details', 'div', 'dl', 'dt', 'fieldset',
            'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hr', 'li', 'main', 'nav',
            'ol', 'p', 'section', 'summary', 'table', 'ul']);
        const chrome = 'nav, footer, aside, body > header, [role="navigation"], [role="banner"], [role="contentinfo"], [role="complementary"], [role="search"]';

        let root = null;
        for (const selector of ['main', '[role="main"]']) {
            const element = document.querySelector(selector);
            if (element && element.innerText.trim().length > 200) {
                root = element;
                break;
            }
        }
        if (!root) {
            const articles = document.querySelectorAll('article');
            if (articles.length === 1 && articles[0].innerText.trim().length > 200) {
                root = articles[0];
            }
        }
        const isWholePage = !root;
        root = root || document.body;
        if (!root) {
            return null;
        }

        const clean = (text) => text.replace(/\\s+/g, ' ').trim();
        const lines = [];
        let line = '';
        let length = 0;
        const flush = () => {
            const text = clean(line);
            line = '';
            if (!text || /^[-#]+$/.test(text)) {
                return;
            }
            lines.push(text);
            length += text.length + 1;
        };
        const isHidden = (element) => {
            if (element.hidden || element.getAttribute('aria-hidden') === 'true') {
                return true;
            }
            // An element laid out as its children alone has no box of its own
            return element.checkVisibility && !element.checkVisibility() && getComputedStyle(element).display !== 'contents';
        };
        const visit = (node) => {
            if (length > limit) {
                return;
            }
            if (node.nodeType === Node.TEXT_NODE) {
                line += node.data;
                return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE) {
                return;
            }
            const element = node;
            const tag = element.localName;
            if (skipped.has(tag) || isHidden(element) || (isWholePage && element.matches(chrome))) {
                return;
            }
            if (tag === 'br') {
                flush();
                return;
            }
            if (tag === 'a' && typeof element.href === 'string' && /^https?:/i.test(element.href)) {
                const text = clean(element.innerText || '');
                if (text) {
                    line += ' [' + text.replace(/[\\[\\]]/g, '') + '](' + element.href + ') ';
                    return;
                }
            }
            if (tag === 'pre') {
                flush();
                const code = (element.innerText || '').trim().slice(0, 4000);
                if (code) {
                    lines.push('```\\n' + code + '\\n```');
                    length += code.length + 8;
                }
                return;
            }
            if (tag === 'tr') {
                flush();
                const cells = Array.from(element.children, (cell) => clean(cell.innerText || ''));
                if (cells.some(Boolean)) {
                    line = '| ' + cells.join(' | ') + ' |';
                    flush();
                }
                return;
            }
            const isBlock = blocks.has(tag);
            if (isBlock) {
                flush();
            }
            if (/^h[1-6]$/.test(tag)) {
                line += '#'.repeat(Number(tag[1])) + ' ';
            } else if (tag === 'li') {
                line += '- ';
            }
            for (const child of element.childNodes) {
                visit(child);
            }
            if (element.shadowRoot) {
                for (const child of element.shadowRoot.childNodes) {
                    visit(child);
                }
            }
            if (isBlock) {
                flush();
            }
        };
        visit(root);
        flush();

        let content = lines.join('\\n');
        if (content.length > limit) {
            content = content.slice(0, limit) + '\\n[The rest of the page is left out]';
        }
        const meta = (selector) => (document.querySelector(selector)?.getAttribute('content') || '').trim();
        return {
            title: document.title || '',
            url: location.href,
            description: meta('meta[name="description"]') || meta('meta[property="og:description"]'),
            selection: (window.getSelection()?.toString() || '').trim().slice(0, 4000),
            content: content
        };
        """

    // MARK: - Selection-based Find Methods

    @MainActor
    func useSelectionForFind() {
        guard let tabManager = tabManager,
              let activeTab = tabManager.activeTab,
              let webView = tabManager.getWebViewForTab(activeTab.id) else { return }

        // Get selected text from WebView
        let selectionScript = """
            (function() {
                var selection = window.getSelection();
                if (selection.rangeCount > 0) {
                    return selection.toString().trim();
                }
                return '';
            })();
        """

        // WebKit answers on the main actor already.
        webView.evaluateJavaScript(selectionScript) { [weak self] result, _ in
            guard let self, let selectedText = result as? String, !selectedText.isEmpty,
                  self.tabManager?.activeTabId == activeTab.id else { return }

            // Show Find panel with selected text and find it right away:
            // starting from the selection, that's its next occurrence
            if self.findState.mode == .chat {
                self.cancelPassageFind()
                self.hideFindUI()
            }
            self.currentTabId = activeTab.id
            self.updateFindState {
                $0.isVisible = true
                $0.mode = .search
                $0.searchText = selectedText
            }
            self.performSearch(selectedText)
        }
    }

    @MainActor
    func jumpToSelection() {
        guard let webView = activeWebView() else { return }

        // WebKit's own Jump to Selection: centers the selection
        // (such as the current match) in the view and flashes the yellow
        // indicator on it.
        let centerSelection = NSSelectorFromString("centerSelectionInVisibleArea:")
        guard webView.responds(to: centerSelection) else {
            logWarning(.webView, "Jump to Selection unavailable: WKWebView lacks centerSelectionInVisibleArea:")
            return
        }
        _ = webView.perform(centerSelection, with: nil)
    }

    // MARK: - Tab Lifecycle Management

    func clearFindStateForTab(_ tabId: UUID) {
        // The tab is closing; its web view, and any find UI in it, goes with
        // it. (A suspended tab keeps its state; see TabManager.suspendTab.)
        tabManager?.tabs.first(where: { $0.id == tabId })?.findState = nil
        if currentTabId == tabId {
            cancelPendingSearch()
            cancelPassageFind()
            stopAnswer()
            findState.isVisible = false
            currentTabId = nil
        }
    }
}

// MARK: - WebKit Find SPI

/// WebKit's find SPI (WKWebViewPrivate.h, _WKFindOptions.h, _WKFindDelegate.h).
/// Private, so feature-detected.
private enum WebKitFind {
    /// `_WKFindOptions`, an NSUInteger bitmask. Bits 0–7 are those of WebKit's
    /// long-standing C API `WKFindOptions`; only the ones used here are listed.
    struct Options: OptionSet {
        let rawValue: UInt

        static let caseInsensitive = Options(rawValue: 1 << 0)
        static let backwards = Options(rawValue: 1 << 3)
        static let wrapAround = Options(rawValue: 1 << 4)
        /// Dims the page around the matches.
        static let showOverlay = Options(rawValue: 1 << 5)
        /// The yellow indicator on the current match.
        static let showFindIndicator = Options(rawValue: 1 << 6)
    }

    private static let findStringSelector = NSSelectorFromString("_findString:options:maxCount:")
    private static let hideFindUISelector = NSSelectorFromString("_hideFindUI")
    private static let setFindDelegateSelector = NSSelectorFromString("_setFindDelegate:")

    static let isAvailable = [findStringSelector, hideFindUISelector, setFindDelegateSelector]
        .allSatisfy { WKWebView.instancesRespond(to: $0) }

    /// WebKit answers on the find delegate: with the match count when the
    /// overlay is on, or that it found nothing.
    static func findString(_ string: String, options: Options, maxCount: Int, in webView: WKWebView) {
        // Three arguments, two of them integers: more than perform(_:with:)
        // can pass, so call the method's implementation as a C function.
        typealias FindStringIMP = @convention(c) (NSObject, Selector, NSString, UInt, UInt) -> Void
        guard let implementation = webView.method(for: findStringSelector) else { return }
        let callFindString = unsafeBitCast(implementation, to: FindStringIMP.self)
        callFindString(webView, findStringSelector, string as NSString, options.rawValue, UInt(maxCount))
    }

    static func hideFindUI(in webView: WKWebView) {
        guard isAvailable else { return }
        _ = webView.perform(hideFindUISelector)
    }

    static func setFindDelegate(_ delegate: NSObject, on webView: WKWebView) {
        _ = webView.perform(setFindDelegateSelector, with: delegate)
    }
}

/// Receives WebKit's `_WKFindDelegate` callbacks. The Objective-C names must
/// match WebKit's selectors exactly: it checks which ones the delegate
/// responds to when the delegate is set.
private final class WebKitFindDelegate: NSObject {
    weak var manager: FindManager?

    init(manager: FindManager) {
        self.manager = manager
        super.init()
    }

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func webView(_ webView: WKWebView, didFindMatches matches: UInt, forString string: String, withMatchIndex matchIndex: Int) {
        // WebKit's match index is a running counter that the page's own
        // selection changes skew, so FindManager keeps the position itself.
        manager?.didFind(string, matchCount: Int(clamping: matches), in: webView)
    }

    @objc(_webView:didFailToFindString:)
    func webView(_ webView: WKWebView, didFailToFindString string: String) {
        manager?.didFailToFind(string, in: webView)
    }
}
