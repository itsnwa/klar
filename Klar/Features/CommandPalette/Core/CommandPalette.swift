import SwiftUI
import AppKit

/// A line of the palette's list: a row with its place in the selection
/// order, under its section's title if it's the first. The list is flat, so
/// the LazyVStack only builds the lines in view.
private struct PaletteListItem: Identifiable {
    struct Title {
        let text: String
        /// False for a title under a row of its section ("Suggestions"
        /// under the top hit).
        let startsSection: Bool
    }

    let id: String
    /// A title is part of its first row's line, so scrolling to the row
    /// brings it along.
    let title: Title?
    let rowIndex: Int
    let suggestion: CommandPaletteState.SuggestionType
    let isTopHit: Bool
}

/// Where the list's lines are in its visible area, for the arrow keys to
/// scroll only when the selected one isn't wholly in view. Geometry
/// actions carry the latest layout even when there are two in a frame,
/// which SwiftUI's visibility reports don't (it skips the second). A
/// reference, so updating it doesn't re-run the palette's body.
private final class PaletteListGeometry {
    var height: CGFloat = 0
    /// The lines built, by ID, in the scroll view's coordinates
    var lineFrames: [String: CGRect] = [:]
}

struct CommandPalette: View {
    @EnvironmentObject var tabManager: TabManager
    /// Owned by ContentView: it outlives each open, along with its tab index.
    @ObservedObject var state: CommandPaletteState
    @StateObject private var settingsManager = TOMLSettingsManager.shared
    @FocusState private var isTextFieldFocused: Bool
    @State private var lastScrollDirection: String? = nil
    @State private var initialScrollDone = false
    @State private var listGeometry = PaletteListGeometry()
    @State private var commandPressed = false
    /// This view's open of `state`, closed when it goes away.
    @State private var paletteSession: UInt?

    var body: some View {
        VStack(spacing: 0) {
          // Search/URL input field
          HStack {
            // Prefix indicator icon
            HStack(spacing: 0) {
              if case .tabActions = state.mode {
                Image(systemName: "command")
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.primary.opacity(0.7))
              } else if case .subview(let sv) = state.mode {
                Image(systemName: leadingIconName(for: sv.id))
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.primary.opacity(0.7))
              } else if state.isInPrefixMode, let shortcut = state.activeShortcut {
                // Show the site's icon when in prefix mode
                SiteShortcutIcon(shortcut: shortcut, size: 22)
              } else if tabManager.isNewTabMode && tabManager.isNewTabPrivate {
                Image(systemName: "sunglasses.fill")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(.primary.opacity(0.7))
                  .help("New private tab")
              } else {
                // Show search icon when not in prefix mode
                Image(systemName: "magnifyingglass")
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.primary.opacity(0.6))
              }
            }
            .frame(width: 22, height: 22)
            
            CustomTextField(
              text: Binding(
                get: { state.displayText },
                set: { newValue in
                  state.handleTextInput(newValue)
                }
              ),
              placeholder: state.placeholderText,
              isFocused: $isTextFieldFocused,
              notificationScope: tabManager,
              onSubmit: {
                // handleSubmit closes the palette itself once it has acted
                // (which can be after the search for the latest text lands).
                state.handleSubmit(commandPressed: commandPressed)
                commandPressed = false // Reset after submit
              },
              onBackspaceWithSelection: {
                // In subview mode, backspace on empty text pops a drill-down level,
                // or returns to the tab actions list when at the subview root.
                if case .subview(let sv) = state.mode, state.userTypedText.isEmpty {
                  if sv.frames.count > 1 {
                    state.popSubviewFrame()
                  } else {
                    state.enterTabActions()
                  }
                  return
                }

                // Tab actions root: backspace on empty text is a no-op.
                if case .tabActions = state.mode, state.userTypedText.isEmpty {
                  return
                }

                // If in prefix mode with empty text, exit prefix mode
                if state.isInPrefixMode && state.displayText.isEmpty {
                  state.exitPrefixMode()
                  return
                }

                // If search is completely empty and not in prefix mode, preserve selection
                if !state.isInPrefixMode && state.userTypedText.isEmpty {
                  // Don't clear selection when backspacing on empty text
                  return
                }

                // Deselect any suggestion in the list
                state.selectedTabIndex = -1
              }
            )
            .frame(maxWidth: .infinity, minHeight: 22)
          }
          .overlay(alignment: .leading) {
            // Large glowing background positioned behind everything
            RoundedRectangle(cornerRadius: 20)
              .fill((state.activeShortcut?.color ?? Color.clear).opacity(0.9))
              .frame(width: 120, height: 58)
              .blur(radius: 120)
              .offset(x: -16)
              .opacity(tabManager.isNewTabMode && state.isInPrefixMode ? 1.0 : 0.0)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 18)
          
          // Breadcrumb (subview drill-down)
          if case .subview(let sv) = state.mode, sv.frames.count > 1 {
            Divider()
              .background(Color.primary)
              .opacity(0.12)
            CommandPaletteBreadcrumb(frames: sv.frames)
          }

          // Content area
          if shouldShowContent() {
            Divider()
              .background(Color.primary)
              .opacity(0.12)
            
            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                  // Top anchor for scroll reset
                  Color.clear.frame(height: 0).id("top")

                  ForEach(listItems()) { item in
                    listLine(item)
                  }

                  // Bottom padding spacer
                  Color.clear.frame(height: 8).id("bottom-spacer")
                }
                .padding(.horizontal, 8)
              }
              .scrollIndicators(.hidden)
              .frame(maxHeight: 300)
              .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                listGeometry.height = height
              }
              .onAppear {
                handleScrollViewAppear(proxy: proxy)
              }
              .onChange(of: state.selectedTabIndex) { oldIndex, newIndex in
                handleSelectionChange(proxy: proxy, newIndex: newIndex)
                state.loadMoreItemsIfNeeded()
              }
              .onChange(of: state.userTypedText) { _, _ in
                // When search text changes, scroll to top to show filtered results
                resetScroll(proxy: proxy)
              }
            }
          }
        }
        // Outside the content area, which isn't there while there are no
        // rows: the search must run on every change regardless.
        .onChange(of: state.userTypedText) { _, newValue in
          state.handleSearchTextChange(newValue)
        }
        .frame(maxWidth: 600)
        .fixedSize(horizontal: false, vertical: true)
        .spaceGlass(in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
          // Set up the command palette when it appears (since it's conditionally rendered)
          paletteSession = state.open()
          focusTextField()
        }
        .onDisappear {
          // Clean up when command palette is removed from view hierarchy
          isTextFieldFocused = false
          if let paletteSession {
            state.close(session: paletteSession)
          }
        }
        .onExitCommand {
          // Same back-navigation hierarchy as .commandPaletteEscape (kept in sync).
          if case .subview(let sv) = state.mode {
            if sv.frames.count > 1 {
              state.popSubviewFrame()
            } else {
              state.enterTabActions()
            }
            return
          }
          // Cancel any pending requests before closing
          SearchSuggestionsService.shared.cancelAllRequests()
          tabManager.showCommandPalette = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .commandPaletteUpArrow, object: tabManager)) { _ in
          if state.selectedTabIndex > 0 {
            lastScrollDirection = "up"
            state.moveSelectionUp()
          }
        }
        .onReceive(NotificationCenter.default.publisher(for: .commandPaletteDownArrow, object: tabManager)) { _ in
          lastScrollDirection = "down"
          state.moveSelectionDown()
        }
        .onReceive(NotificationCenter.default.publisher(for: .commandPaletteReturn, object: tabManager)) { notification in
          // Get command key state from the keyboard handler notification
          let keyboardCommandPressed = notification.userInfo?["commandPressed"] as? Bool ?? false
          state.handleSubmit(commandPressed: keyboardCommandPressed || commandPressed)
          commandPressed = false // Reset after submit
        }
        .onReceive(NotificationCenter.default.publisher(for: .commandPaletteUpdateSelection, object: tabManager)) { _ in
          // Tabs were closed or unloaded (or a history entry deleted): refresh the rows
          state.refreshAfterTabsChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SetPrefilledURL"), object: tabManager)) { notification in
          if let url = notification.userInfo?["url"] as? String {
            state.setPrefilledURL(url)
          }
        }
        .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRefocus, object: tabManager)) { _ in
          // Ensure the text field stays focused when tabs are updated
          DispatchQueue.main.async {
            isTextFieldFocused = true
          }
        }
        .onReceive(NotificationCenter.default.publisher(for: .commandPaletteEscape, object: tabManager)) { _ in
          // Back-navigation hierarchy:
          //   subview deeper than root  → pop one frame
          //   subview at root           → return to the tab actions list
          //   tab actions               → dismiss
          //   normal                    → dismiss
          if case .subview(let sv) = state.mode {
            if sv.frames.count > 1 {
              state.popSubviewFrame()
            } else {
              state.enterTabActions()
            }
            return
          }
          SearchSuggestionsService.shared.cancelAllRequests()
          tabManager.showCommandPalette = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CommandPaletteSubmit"), object: tabManager)) { notification in
          if let userInfo = notification.userInfo,
             let commandPressed = userInfo["commandPressed"] as? Bool {
            self.commandPressed = commandPressed
          }
        }
    }
    
    // MARK: - List

    /// The sections' rows, in order, each section's title with its first.
    private func listItems() -> [PaletteListItem] {
        var items: [PaletteListItem] = []
        var rowIDs = Set<String>()
        var pendingTitle: PaletteListItem.Title?

        /// The title of the next row's section. Every section shown has a row.
        func title(_ text: String, startsSection: Bool = true) {
            pendingTitle = PaletteListItem.Title(text: text, startsSection: startsSection)
        }
        func row(_ index: Int, _ suggestion: CommandPaletteState.SuggestionType, id: String, isTopHit: Bool = false) {
            // Two rows can show the same thing (a suggestion that's also
            // the text typed), but not share an ID.
            var uniqueID = id
            var copy = 1
            while !rowIDs.insert(uniqueID).inserted {
                copy += 1
                uniqueID = "\(id)#\(copy)"
            }
            items.append(PaletteListItem(id: uniqueID, title: pendingTitle, rowIndex: index, suggestion: suggestion, isTopHit: isTopHit))
            pendingTitle = nil
        }

        for section in state.calculateSectionInfos() {
            let start = section.startIndex
            switch section.type {
            case .update:
                if let update = state.readyUpdate {
                    title("Update")
                    row(start, .update(update), id: "update")
                }
            case .tabs:
                title("Tabs")
                for (offset, tab) in state.filteredTabs.enumerated() {
                    row(start + offset, .tab(tab), id: "tab-\(tab.id)")
                }
            case .urlSuggestions:
                for (offset, entry) in state.urlSuggestions.enumerated() {
                    if offset == 0 {
                        title(state.isInPrefixMode ? "Earlier \(state.activeShortcut?.name ?? "") Searches" : "Top Hit")
                    } else if offset == 1 && !state.isInPrefixMode {
                        title("Suggestions", startsSection: false)
                    }
                    row(start + offset, .urlSuggestion(entry), id: "url-\(entry.url)", isTopHit: offset == 0 && !state.isInPrefixMode)
                }
            case .searchResults:
                title("Results")
                for (offset, result) in state.combinedSearchResults.enumerated() {
                    row(start + offset, .searchResult(result), id: "search-result-\(result.id)")
                }
            case .directURL:
                if let url = state.directURLSuggestion {
                    title(DeepLinkHandler.shared.shouldHandleAsDeepLink(url) ? "Open" : "Navigate")
                    row(start, .directURL(url), id: "direct-url")
                }
            case .searchEngines:
                title("Search with")
                for (offset, engine) in state.searchEngineSuggestions.enumerated() {
                    row(start + offset, .searchEngine(engine), id: "engine-\(engine.id)")
                }
            case .googleSuggestions:
                // After a site shortcut the suggestions search its site
                let siteName = state.isInPrefixMode ? state.activeShortcut?.name : nil
                title(siteName.map { "Search \($0)" } ?? "\(settingsManager.defaultSearchEngine.displayName) Suggestions")
                // First the query itself (see hasExactTextRow)
                var offset = 0
                if state.hasExactTextRow {
                    row(start, .googleSuggestion(state.displayedQuery), id: "search-exact")
                    offset = 1
                }
                for (suggestionOffset, suggestion) in state.googleSuggestions.enumerated() {
                    row(start + offset + suggestionOffset, .googleSuggestion(suggestion), id: "search-\(suggestion)")
                }
            case .tabActions:
                title("Tab actions")
                for (offset, action) in state.tabActions.enumerated() {
                    row(start + offset, .tabAction(action), id: "tabaction-\(action.id)")
                }
            case .subview:
                for (offset, subviewRow) in state.subviewRows.enumerated() {
                    row(start + offset, .subviewRow(subviewRow), id: "subrow-\(subviewRow.id)")
                }
            }
        }
        return items
    }

    /// The spacing of a VStack per section: titles 8 pt below the section
    /// before, rows 4 pt below what's above them.
    private func listLine(_ item: PaletteListItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = item.title {
                Text(title.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.top, title.startsSection ? 8 : 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            listRow(index: item.rowIndex, suggestion: item.suggestion, isTopHit: item.isTopHit)
                .padding(.top, 4)
        }
        .id(item.id)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
            listGeometry.lineFrames[item.id] = frame
        }
        .onDisappear {
            listGeometry.lineFrames[item.id] = nil
        }
    }

    /// Where the arrow keys keep a line from the list's edges, so its row
    /// is 8 pt from them: above, 8 pt less the 4 pt above the row. Not
    /// padding around the line with the room taken back by negative
    /// spacing, which the LazyVStack's height leaves out: the palette came
    /// out taller than its rows.
    private static let scrollMargin = (top: CGFloat(4), bottom: CGFloat(8))

    @ViewBuilder
    private func listRow(index: Int, suggestion: CommandPaletteState.SuggestionType, isTopHit: Bool) -> some View {
        let isSelected = index == state.selectedTabIndex
        switch suggestion {
        case .tabAction(let action):
            CommandPaletteRow(
                isSelected: isSelected,
                onTap: {
                    guard action.isEnabled else { return }
                    state.selectedTabIndex = index
                    state.handleSubmit()
                }
            ) {
                paletteSimpleRow(
                    icon: action.systemIcon,
                    title: action.title,
                    subtitle: action.subtitle,
                    isSelected: isSelected,
                    trailingKeys: action.keyboardShortcut
                )
                .opacity(action.isEnabled ? 1.0 : 0.4)
            }
        case .subviewRow(let row):
            CommandPaletteRow(
                isSelected: isSelected,
                onTap: {
                    state.selectedTabIndex = index
                    state.handleSubmit()
                }
            ) {
                paletteSimpleRow(
                    icon: row.systemIcon,
                    title: row.title,
                    subtitle: row.subtitle,
                    isSelected: isSelected,
                    trailingChevron: trailingChevron(for: row)
                )
            }
        case .none:
            EmptyView()
        default:
            CommandPaletteRow(
                isSelected: isSelected,
                onTap: { activateRow(at: index) }
            ) {
                rowContent(suggestion, isSelected: isSelected, isTopHit: isTopHit)
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ suggestion: CommandPaletteState.SuggestionType, isSelected: Bool, isTopHit: Bool) -> some View {
        switch suggestion {
        case .update(let update):
            UpdateRow(update: update, isSelected: isSelected)
        case .tab(let tab):
            TabRow(
                tab: tab,
                isSelected: isSelected,
                isActive: tab.id == tabManager.activeTabId
            )
        case .urlSuggestion(let entry):
            URLSuggestionRow(
                suggestion: entry,
                isSelected: isSelected,
                isTopHit: isTopHit
            )
        case .searchResult(let result):
            switch result {
            case .tab(let tab, _):
                TabRow(
                    tab: tab,
                    isSelected: isSelected,
                    isActive: tab.id == tabManager.activeTabId
                )
            case .history(let entry, _):
                URLSuggestionRow(
                    suggestion: entry,
                    isSelected: isSelected,
                    isTopHit: false  // In combined results, no special top hit treatment
                )
            case .site(let host):
                PopularSiteRow(host: host, isSelected: isSelected)
            case .readingList(let item, _):
                ReadingListSuggestionRow(item: item, isSelected: isSelected)
            }
        case .directURL(let url):
            DirectURLRow(
                url: url,
                isSelected: isSelected,
                isPopularSite: state.directURLIsPopularSite
            )
        case .searchEngine(let engine):
            SearchEngineRow(
                shortcut: engine,
                query: state.displayedQuery,
                isSelected: isSelected
            )
        case .googleSuggestion(let suggestion):
            GoogleSuggestionRow(
                suggestion: suggestion,
                isSelected: isSelected,
                siteName: state.isInPrefixMode ? state.activeShortcut?.name : nil
            )
        case .tabAction, .subviewRow, .none:
            EmptyView()
        }
    }

    private func leadingIconName(for id: PaletteSubviewID) -> String {
        switch id {
        case .folderPicker:
            return FolderIcons.groupSymbol
        case .explore:
            return "sparkles"
        }
    }

    private func trailingChevron(for row: PaletteSubviewRow) -> Bool {
        if case .folder(_, let hasSubfolders) = row.kind { return hasSubfolders }
        return false
    }

    @ViewBuilder
    private func paletteSimpleRow(icon: String,
                                  title: String,
                                  subtitle: String?,
                                  isSelected: Bool,
                                  trailingChevron: Bool = false,
                                  trailingKeys: [String]? = nil) -> some View {
        HStack(spacing: 12) {
            paletteRowIcon(icon, isSelected: isSelected)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .white.opacity(0.7) : .primary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if let keys = trailingKeys, !keys.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        Text(key)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(isSelected ? .white.opacity(0.8) : .primary.opacity(0.8))
                            .frame(width: 19, height: 19)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(5)
                    }
                }
            }

            if trailingChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .primary.opacity(0.4))
            }
        }
    }

    @ViewBuilder
    private func paletteRowIcon(_ icon: String, isSelected: Bool) -> some View {
        if case .emoji(let emoji) = Icomoji(icon) {
            // A folder's emoji
            Text(emoji)
                .font(.system(size: 15))
                .frame(width: 22, height: 22, alignment: .center)
        } else if CuratedFolderIcons.isBrandIcon(icon) {
            Image(icon)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(isSelected ? .white : .primary.opacity(0.85))
                .frame(width: 16, height: 16)
                .frame(width: 22, height: 22, alignment: .center)
        } else {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(isSelected ? .white : .primary.opacity(0.85))
                .frame(width: 22, height: 22, alignment: .center)
        }
    }
    
    // MARK: - Scroll Helper Methods

    /// The list's line for the row at `index` in the selection order
    private func listItemID(forRow index: Int) -> String? {
        listItems().first { $0.rowIndex == index }?.id
    }

    /// Whether the line is in view with its margins from the list's edges
    private func isWhollyInView(_ lineID: String) -> Bool {
        guard let frame = listGeometry.lineFrames[lineID] else { return false }
        return frame.minY >= Self.scrollMargin.top - 0.5
            && frame.maxY <= listGeometry.height - Self.scrollMargin.bottom + 0.5
    }

    /// The anchor that puts the line its margin from the top or bottom
    /// edge: scrollTo lines up the point at `y` of the line with the point
    /// at `y` of the list, so the line's top lands at `y × (list − line)`.
    /// A line not built yet goes to the edge itself.
    private func scrollAnchor(for lineID: String, atTop: Bool) -> UnitPoint {
        guard let frame = listGeometry.lineFrames[lineID] else { return atTop ? .top : .bottom }
        let room = listGeometry.height - frame.height
        guard room > 0 else { return .top }
        let top = atTop ? Self.scrollMargin.top : room - Self.scrollMargin.bottom
        return UnitPoint(x: 0.5, y: min(max(top / room, 0), 1))
    }

    // MARK: - Helper Methods
    
    /// A click on a row does what Return does with it selected.
    private func activateRow(at index: Int) {
        state.activateRow(at: index, commandPressed: NSEvent.modifierFlags.contains(.command))
    }
    
    private func shouldShowContent() -> Bool {
        return state.getTotalSuggestionCount() > 0
    }
    
    private func resetScroll(proxy: ScrollViewProxy) {
        // Reset scroll state when content changes
        initialScrollDone = false
        lastScrollDirection = nil

        // After content updates, scroll to top (position 0)
        // This is more efficient than calculating scroll ID for first item
        DispatchQueue.main.async {
            proxy.scrollTo("top", anchor: .top)
        }
    }
    
    private func focusTextField() {
        // The field takes focus as it enters the window; this is in case it
        // couldn't then (the window not key yet, say). It doesn't take a
        // field already being typed in.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("ForceTextSelection"), object: tabManager)
        }
    }
    
    private func handleScrollViewAppear(proxy: ScrollViewProxy) {
        // Initial scroll when the scroll view appears
        if !initialScrollDone {
            // Reduce delay for more responsive scrolling
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let scrollID = listItemID(forRow: state.selectedTabIndex) {
                    proxy.scrollTo(scrollID, anchor: .center)
                }
                initialScrollDone = true
            }
        }
    }

    private func handleSelectionChange(proxy: ScrollViewProxy, newIndex: Int) {
        // Smart scroll - only scroll when necessary to keep item visible
        guard newIndex >= 0 else { return }

        // Only scroll if there was a direction change (arrow navigation)
        if let direction = lastScrollDirection {
            // The row's line (with its section's title and 8 pt around it)
            // goes to the edge it's past, and stays put while wholly in view.
            // Not scrollTo with no anchor, which should do the same but left
            // a line partly above the top where it was.
            if let rowID = listItemID(forRow: newIndex), !isWhollyInView(rowID) {
                // A line not built yet is past the edge the selection moves to
                let isAbove = listGeometry.lineFrames[rowID].map { $0.minY < Self.scrollMargin.top } ?? (direction == "up")
                proxy.scrollTo(rowID, anchor: scrollAnchor(for: rowID, atTop: isAbove))
            }
        } else {
            // Initial scroll to center the selected item (when command palette opens)
            DispatchQueue.main.async {
                if let rowID = listItemID(forRow: newIndex) {
                    proxy.scrollTo(rowID, anchor: .center)
                }
            }
        }

        // Reset direction after handling
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            lastScrollDirection = nil
        }
    }
}
