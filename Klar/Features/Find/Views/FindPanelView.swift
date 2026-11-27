import SwiftUI
import Foundation

enum FindPanelField: Hashable {
    case search
    case chat
}

/// Bridges the panel's @FocusState to the manager so external callers
/// (Cmd+F shortcut, menu) can decide whether to focus or close the panel.
private struct FindFocusController: ViewModifier {
    @ObservedObject var findManager: FindManager
    var focusedField: FocusState<FindPanelField?>.Binding

    func body(content: Content) -> some View {
        content
            .task(id: findManager.findState.isVisible) {
                guard findManager.findState.isVisible else { return }
                try? await Task.sleep(for: .milliseconds(150))
                await MainActor.run {
                    focusedField.wrappedValue = preferredField()
                }
            }
            .onChange(of: focusedField.wrappedValue) { _, newValue in
                findManager.isInputFocused = newValue != nil
            }
            .onChange(of: findManager.focusRequest) { _, newValue in
                guard newValue != nil, findManager.findState.isVisible else { return }
                focusedField.wrappedValue = preferredField()
            }
            .onChange(of: findManager.findState.mode) { _, _ in
                guard findManager.findState.isVisible, focusedField.wrappedValue != nil else { return }
                focusedField.wrappedValue = preferredField()
            }
    }

    private func preferredField() -> FindPanelField {
        findManager.findState.mode == .search ? .search : .chat
    }
}

struct FindPanelView: View {
    @ObservedObject var findManager: FindManager
    var availableHeight: CGFloat = 600
    @FocusState private var focusedField: FindPanelField?

    // Animation and sizing constants
    private let searchModeHeight: CGFloat = 36
    private let minChatHeight: CGFloat = 36
    private let searchPanelWidth: CGFloat = 320
    /// Wider for answers, with their tables, code and link cards
    private let chatPanelWidth: CGFloat = 400
    private let chatPadding: CGFloat = 14
    private let cornerRadius: CGFloat = 16
    private let shadowRadius: CGFloat = 16

    // The chat's height follows its content, up to the room there is
    @State private var messagesHeight: CGFloat = 0
    @State private var composerHeight: CGFloat = 53
    @State private var chatScroll = ScrollPosition(edge: .bottom)

    var body: some View {
        if findManager.findState.isVisible {
            findPanelContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity),
                    removal: .scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity)
                ))
        }
    }

    private var isChat: Bool {
        findManager.findState.mode == .chat
    }

    private var dynamicChatHeight: CGFloat {
        // availableHeight already accounts for the 8pt top/bottom padding around the panel
        return min(max(chatHeaderHeight + messagesHeight + composerHeight, minChatHeight), max(availableHeight, minChatHeight))
    }

    @ViewBuilder
    private var findPanelContent: some View {
        VStack(spacing: 0) {
            if isChat {
                chatModeView
            } else {
                searchModeView
            }
        }
        .frame(width: isChat ? chatPanelWidth : searchPanelWidth)
        // Only the height springs: animating the whole panel with it would
        // animate each streamed word in too
        .animation(.spring(response: 0.4, dampingFraction: 0.8)) { content in
            content.frame(height: isChat ? dynamicChatHeight : searchModeHeight)
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.3), radius: shadowRadius, x: -2, y: 4)
        .modifier(FindFocusController(findManager: findManager, focusedField: $focusedField))
    }

    // MARK: - Search Mode View

    @ViewBuilder
    private var searchModeView: some View {
        HStack(spacing: 0) {
            // Search icon
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 20)

            // Search text field with embedded controls
            ZStack {
                // Background for text field
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.clear)

                HStack(spacing: 0) {
                    // Text field
                    TextField("Find on page", text: Binding(
                        get: { findManager.findState.searchText },
                        set: { findManager.updateSearchText($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .regular))
                    .focused($focusedField, equals: .search)
                    .onSubmit {
                        // Mirror the visible affordance: if "Ask AI" button is showing,
                        // Enter should trigger it; otherwise navigate to next match.
                        if findManager.findState.shouldShowAIFallback {
                            findManager.switchToAIChat(submitSearch: true)
                        } else if findManager.findState.findResult.hasResults {
                            findManager.findNext()
                        }
                    }

                    // Right side controls (result count + arrows + AI button)
                    HStack(spacing: 4) {
                        if !findManager.findState.searchText.isEmpty, findManager.findState.findResult.hasResults {
                            // Keep the count and navigation up while a refined query searches.
                            resultCounter
                            navigationButtons
                        } else if findManager.findState.isSearching {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        aiChatButton
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 24)

            // Close button
            Button(action: { findManager.hideFind() }) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12, weight: .regular))
            }
            .buttonStyle(PlainButtonStyle())
            .frame(width: 20, height: 20)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Chat Mode View

    private let chatHeaderHeight: CGFloat = 40

    @ViewBuilder
    private var chatModeView: some View {
        let passage = findManager.passageFind
        VStack(spacing: 0) {
            chatHeader
                .frame(height: chatHeaderHeight)
                .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if findManager.findState.chatMessages.isEmpty {
                        chatStarters
                    }
                    ForEach(findManager.findState.chatMessages) { message in
                        ChatMessageView(
                            message: message,
                            isLast: message.id == findManager.findState.chatMessages.last?.id,
                            contentWidth: chatPanelWidth - 2 * chatPadding,
                            inset: chatPadding,
                            passage: passage?.messageID == message.id ? passage : nil,
                            findManager: findManager
                        )
                        .equatable()
                    }
                }
                .padding(.horizontal, chatPadding)
                .padding(.bottom, 14)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    messagesHeight = height
                }
            }
            .scrollPosition($chatScroll)
            .onScrollGeometryChange(for: ChatScrollMetrics.self) { geometry in
                ChatScrollMetrics(
                    contentHeight: geometry.contentSize.height,
                    distanceFromBottom: geometry.contentSize.height - geometry.visibleRect.maxY
                )
            } action: { old, new in
                // Down with the answer as it grows, unless scrolled up to
                // read an earlier part
                if new.contentHeight > old.contentHeight, old.distanceFromBottom < 24 {
                    chatScroll.scrollTo(edge: .bottom)
                }
            }
            .onChange(of: findManager.findState.chatMessages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    chatScroll.scrollTo(edge: .bottom)
                }
            }
            // Links in answers open in a new tab, ⌘-clicked in the background
            .environment(\.openURL, OpenURLAction { url in
                findManager.openLink(url, inBackground: NSEvent.modifierFlags.contains(.command))
                return .handled
            })

            Divider()

            chatComposer
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    // And the divider above it
                    composerHeight = height + 1
                }
        }
    }

    // MARK: - UI Components

    @ViewBuilder
    private var aiChatButton: some View {
        if findManager.findState.shouldShowAIFallback {
            Button("Ask AI") {
                findManager.switchToAIChat(submitSearch: true)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.mini)
            .font(.system(size: 11, weight: .medium))
        } else {
            headerButton(symbol: "sparkles", help: "Ask AI about this page") {
                findManager.switchToAIChat()
            }
        }
    }

    @ViewBuilder
    private var resultCounter: some View {
        // No count to show (the public-API fallback, or a page that has just
        // navigated): arrows only
        if let displayText = findManager.findState.findResult.displayText {
            Text(displayText)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var navigationButtons: some View {
        HStack(spacing: 4) {
            Button(action: { findManager.findPrevious() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(findManager.findState.findResult.hasResults ? .secondary : .secondary.opacity(0.3))
            }
            .buttonStyle(PlainButtonStyle())
            .frame(width: 12, height: 12)
            .disabled(!findManager.findState.findResult.hasResults)

            Button(action: { findManager.findNext() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(findManager.findState.findResult.hasResults ? .secondary : .secondary.opacity(0.3))
            }
            .buttonStyle(PlainButtonStyle())
            .frame(width: 12, height: 12)
            .disabled(!findManager.findState.findResult.hasResults)
        }
    }

    @ViewBuilder
    private var chatHeader: some View {
        HStack(spacing: 0) {
            headerButton(symbol: "chevron.left", help: "Back to Find on Page") {
                findManager.switchToSearch()
            }
            Spacer()
            headerButton(symbol: "xmark", help: "Close") {
                findManager.hideFind()
            }
        }
        .padding(.horizontal, 8)
    }

    private func headerButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    private var chatStarters: some View {
        HStack(spacing: 8) {
            chatStarter("Summarize", question: "Summarize this page.")
            chatStarter("Key points", question: "What are the key points on this page?")
            chatStarter("Explain simply", question: "Explain this page in simple terms.")
        }
    }

    private func chatStarter(_ title: String, question: String) -> some View {
        Button(title) {
            findManager.sendChatMessage(question)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    /// The question field, growing to a few lines, and Send, which turns into
    /// Stop while an answer is coming. Return sends; ⌥Return starts a new line.
    @ViewBuilder
    private var chatComposer: some View {
        let state = findManager.findState
        let canSend = !state.chatInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .center, spacing: 10) {
            TextField(state.chatMessages.isEmpty ? "Ask about this page…" : "Ask a follow-up…", text: Binding(
                get: { findManager.findState.chatInputText },
                set: { findManager.findState.chatInputText = $0 }
            ), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($focusedField, equals: .chat)
                .onSubmit {
                    findManager.sendChatMessage(findManager.findState.chatInputText)
                }
                .padding(.vertical, 4)

            Button {
                if findManager.findState.isAnswering {
                    findManager.stopAnswer()
                } else {
                    findManager.sendChatMessage(findManager.findState.chatInputText)
                }
            } label: {
                Image(systemName: state.isAnswering ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .disabled(!state.isAnswering && !canSend)
            .help(state.isAnswering ? "Stop" : "Send")
        }
        .padding(.leading, chatPadding)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    // MARK: - Background and Effects

    /// Glass in the space's color, as the command palette has it. On an
    /// empty view: a filled shape's fill would cover the glass.
    private var panelBackground: some View {
        Color.clear
            .spaceGlass(in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

private struct ChatScrollMetrics: Equatable {
    var contentHeight: CGFloat
    var distanceFromBottom: CGFloat
}

// MARK: - Chat Message

/// A question, in a bubble, or an answer: its Markdown, then link cards and
/// Copy and Try Again once it's done. Only runs again when its message
/// changes, not for every word streamed into the one after it.
private struct ChatMessageView: View, Equatable {
    let message: ChatMessage
    let isLast: Bool
    let contentWidth: CGFloat
    /// The chat's side padding, which link cards scroll out into
    let inset: CGFloat
    let passage: PassageFind?
    /// Not observed: the message is all this shows of it
    let findManager: FindManager
    @State private var isHovered = false

    static func == (lhs: ChatMessageView, rhs: ChatMessageView) -> Bool {
        lhs.message == rhs.message && lhs.isLast == rhs.isLast && lhs.contentWidth == rhs.contentWidth
            && lhs.passage == rhs.passage
    }

    var body: some View {
        if message.isUser {
            HStack(spacing: 0) {
                Spacer(minLength: 48)
                Text(message.content)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            answer
        }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.content.isEmpty {
                if message.isStreaming {
                    TypingIndicator()
                }
            } else {
                MarkdownView(
                    blocks: message.document.blocks,
                    width: contentWidth,
                    passage: passage,
                    showQuote: !message.isStreaming && message.hasPageContent && message.pageURL != nil
                        ? { findManager.showPassage(inMessage: message.id, blockID: $0) }
                        : nil
                )
            }

            switch message.outcome {
            case .failed(let reason):
                AnswerFailureView(reason: reason, retry: isLast ? { findManager.retryAnswer(message.id) } : nil)
            case .stopped:
                Label("Stopped", systemImage: "stop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            case .answered:
                EmptyView()
            }

            if !message.isStreaming {
                let links = message.document.links.filter { ExplorePreviews.isPublicWebAddress($0.url) }
                if !links.isEmpty {
                    LinkCardsView(
                        links: links,
                        previews: message.linkPreviews,
                        inset: inset,
                        load: { url in
                            await findManager.loadLinkPreview(for: url, inMessage: message.id)
                        },
                        open: { url, inBackground in
                            findManager.openLink(url, inBackground: inBackground)
                        }
                    )
                    .padding(.top, 2)
                }

                if !message.content.isEmpty {
                    answerActions
                }
            }
        }
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
    }

    private var answerActions: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                CopyButton(text: message.content)
                if isLast, message.outcome == .answered || message.outcome == .stopped {
                    ChatIconButton(symbol: "arrow.clockwise", help: "Try Again") {
                        findManager.retryAnswer(message.id)
                    }
                }
            }
            .opacity(isLast || isHovered ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovered)

            if let provider = message.provider {
                HStack(spacing: 4) {
                    Image(provider.iconName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text(provider.title)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, -6)
    }
}

private struct ChatIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 24, height: 22)
                .background(Color.primary.opacity(isHovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
    }
}

private struct AnswerFailureView: View {
    let reason: String
    /// Nil past the last answer
    let retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Couldn’t get an answer")
                    .font(.system(size: 12, weight: .semibold))
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Button("Try Again", action: retry)
                        .controlSize(.small)
                        .padding(.top, 5)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Typing Indicator

/// Three dots pulsing in turn, until an answer's first words
struct TypingIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (sin(time * 2 * .pi / 1.2 - Double(index) * 0.7) + 1) / 2
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(0.7 + 0.3 * phase)
                        .opacity(0.35 + 0.65 * phase)
                }
            }
        }
        .frame(height: 18, alignment: .leading)
        .accessibilityLabel("Answering")
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Spacer()
        HStack {
            Spacer()
            FindPanelView(findManager: FindManager())
                .padding()
        }
    }
    .frame(width: 400, height: 400)
    .background(Color.black.opacity(0.1))
}
