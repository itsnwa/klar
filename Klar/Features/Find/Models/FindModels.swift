import AppKit

// MARK: - Find Panel State

enum FindPanelMode {
    case search
    case chat
}

// MARK: - Find Result

struct FindResult: Equatable {
    /// How many matches WebKit reported.
    enum Count: Equatable {
        case exact(Int)
        /// More than WebKit was asked to count.
        case atLeast(Int)
        /// Found, but not counted: the public `WKWebView.find` fallback only
        /// says whether there's a match, and after the page navigates the
        /// old count no longer applies.
        case unknown
    }

    /// Nil when nothing matched, or nothing was searched.
    var count: Count? = nil
    /// 1-based position of the current match, counted from where the search
    /// started; kept for exact counts only.
    var currentResult: Int = 0

    var hasResults: Bool {
        count != nil
    }

    var isEmpty: Bool {
        count == nil
    }

    /// The panel's match counter; nil when there's no count to show.
    var displayText: String? {
        guard let count else { return nil }
        switch count {
        case .exact(let total):
            return "\(min(max(currentResult, 1), total)) of \(total)"
        case .atLeast(let limit):
            return "\(limit)+ matches"
        case .unknown:
            return nil
        }
    }
}

// MARK: - Chat Message

/// A question, or the AI's answer to it.
struct ChatMessage: Identifiable, Equatable {
    enum Outcome: Equatable {
        case answered
        /// Stopped before it was done; what came so far stays
        case stopped
        case failed(String)
    }

    let id = UUID()
    let isUser: Bool
    private(set) var content: String
    /// An answer still being written
    private(set) var isStreaming: Bool
    private(set) var outcome = Outcome.answered
    /// An answer's Markdown, parsed as it comes
    private(set) var document = MarkdownDocument()
    /// The page an answer is about: its relative links are relative to it
    let pageURL: URL?
    /// The provider chosen when this answer was requested
    var provider: AIProvider?
    /// Whether the provider received text from the page
    var hasPageContent = false
    /// What each of an answer's link cards shows, fetched as the card first
    /// shows. Kept with the chat, so it's gone with it (and its tab).
    var linkPreviews: [URL: LinkPreview] = [:]

    static func question(_ text: String) -> ChatMessage {
        ChatMessage(isUser: true, content: text, isStreaming: false, pageURL: nil)
    }

    /// An answer on its way
    static func answer(about pageURL: URL?) -> ChatMessage {
        ChatMessage(isUser: false, content: "", isStreaming: true, pageURL: pageURL)
    }

    private init(isUser: Bool, content: String, isStreaming: Bool, pageURL: URL?) {
        self.isUser = isUser
        self.content = content
        self.isStreaming = isStreaming
        self.pageURL = pageURL
    }

    mutating func append(_ text: String) {
        guard isStreaming else { return }
        content += text
        document.append(text)
    }

    mutating func finish() {
        guard isStreaming else { return }
        isStreaming = false
        document.finish(base: pageURL)
    }

    mutating func stop() {
        guard isStreaming else { return }
        finish()
        outcome = .stopped
    }

    mutating func fail(_ reason: String) {
        finish()
        outcome = .failed(reason)
    }

    /// The document follows from the content
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.isStreaming == rhs.isStreaming
            && lhs.outcome == rhs.outcome
            && lhs.content == rhs.content
            && lhs.provider == rhs.provider
            && lhs.hasPageContent == rhs.hasPageContent
            && lhs.linkPreviews == rhs.linkPreviews
    }
}

/// What a link card shows of the page it links to.
struct LinkPreview: Equatable {
    var title: String?
    var summary: String?
    var siteName: String?
    /// The page's sharing image, at the card's size
    var image: NSImage?
    var icon: NSImage?

    static func == (lhs: LinkPreview, rhs: LinkPreview) -> Bool {
        lhs.title == rhs.title && lhs.summary == rhs.summary && lhs.siteName == rhs.siteName
            && lhs.image === rhs.image && lhs.icon === rhs.icon
    }
}

struct PassageFind: Equatable {
    enum Status: Equatable {
        case searching
        case notFound
        case differentPage
    }

    let messageID: UUID
    let blockID: Int
    var status: Status = .searching
}

// MARK: - Find State

struct FindState: Equatable {
    var isVisible: Bool = false
    var searchText: String = ""
    var chatInputText: String = ""
    var mode: FindPanelMode = .search
    var findResult = FindResult()
    var isSearching: Bool = false
    var chatMessages: [ChatMessage] = []

    /// An answer is on its way
    var isAnswering: Bool {
        chatMessages.last?.isStreaming == true
    }

    var hasNoSearchResults: Bool {
        return !searchText.isEmpty && !isSearching && findResult.isEmpty
    }
    
    var shouldShowAIFallback: Bool {
        return hasNoSearchResults && mode == .search
    }
}

// MARK: - Ollama Models

struct OllamaRequest: Codable {
    let model: String
    let system: String?
    let prompt: String
    let stream: Bool
}

struct OllamaResponse: Codable {
    let response: String?
    let done: Bool?
    let error: String?
}
