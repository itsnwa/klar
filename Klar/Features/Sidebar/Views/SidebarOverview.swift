import SwiftUI
import AppKit

// MARK: - Overview

/// Live cards for Downloads, the Reading List, History and Explore with AI's
/// pages, then a card for each space. Opening anything goes back to the space you came from.
struct SidebarOverview: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(SidebarStateManager.self) var sidebarStateManager
    @ObservedObject private var spaceManager = SpaceManager.shared
    @EnvironmentObject private var spaceSelection: SpaceSelection

    private var accent: Color {
        spaceSelection.activeSpace?.color.color ?? .accentColor
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                DownloadsOverviewCard(accent: accent, onOpen: zoomBack)
                ReadingListOverviewCard(accent: accent, open: open)
                HistoryOverviewCard(history: spaceSelection.activeHistory, accent: accent, open: open)
                ExploreOverviewCard(accent: accent, open: open)

                Text("Spaces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(spaceManager.spaces) { space in
                        SpaceCard(
                            space: space,
                            isCurrent: space.id == spaceSelection.currentSpaceID,
                            tabCount: spaceSelection.tabCount(inSpace: space.id),
                            action: {
                                spaceSelection.switchTo(space.id)
                                zoomBack()
                            }
                        )
                    }
                    NewSpaceCard {
                        spaceManager.createSpace(switchingIn: spaceSelection)
                        zoomBack()
                    }
                }
            }
            .padding(.horizontal, 6)
            // As close under the URL bar as the pinned sites are at the
            // other levels, rather than the lists' 16 pt
            .padding(.top, PinnedSitesSection.topInset - SidebarLayoutMetrics.topSeparatorInset)
            .padding(.bottom, SidebarLayoutMetrics.contentBottomInsideSeparator)
        }
        .sidebarScrollEdgeSeparators()
    }

    /// Opens a page in the active space and zooms back into it, or in a
    /// background tab, staying here.
    private func open(_ url: String, inBackground: Bool) {
        tabManager.openFromLibrary(url: url, inBackground: inBackground)
        if !inBackground {
            zoomBack()
        }
    }

    private func zoomBack() {
        sidebarStateManager.show(.space)
    }
}

// MARK: Cards

/// A library card: a header that zooms into the full list, then a few items.
private struct OverviewCard<Content: View>: View {
    let list: SidebarLibraryList
    let trailing: String
    let accent: Color
    @ViewBuilder let content: Content
    @Environment(SidebarStateManager.self) var sidebarStateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OverviewRow(action: { sidebarStateManager.show(.list(list)) }) {
                HStack(spacing: 8) {
                    Image(systemName: list.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 16)
                    Text(list.title)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(height: 20)
            }
            .help("Show all \(list.title)")

            content
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}

/// A row of a card, highlighted under the pointer.
private struct OverviewRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(isHovering ? 0.08 : 0)))
        .onHover { hovering in
            if isHovering != hovering {
                isHovering = hovering
            }
        }
    }
}

private struct CardPlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

private struct DownloadsOverviewCard: View {
    let accent: Color
    let onOpen: () -> Void
    @ObservedObject private var downloadManager = DownloadManager.shared
    @EnvironmentObject var tabManager: TabManager
    @Environment(SidebarStateManager.self) var sidebarStateManager

    var body: some View {
        let downloads = downloadManager.downloads
        OverviewCard(list: .downloads, trailing: downloads.isEmpty ? "" : "\(downloads.count)", accent: accent) {
            if downloads.isEmpty {
                CardPlaceholder(text: "No downloads")
            } else {
                ForEach(downloads.prefix(2)) { item in
                    DownloadPreviewRow(item: item, accent: accent) {
                        if item.state == .completed {
                            openFile(of: item)
                        } else {
                            sidebarStateManager.show(.list(.downloads))
                        }
                    }
                    .libraryContextMenu { menu, _ in
                        SidebarLibraryMenus.addItems(to: menu, for: item, tabManager: tabManager) {
                            openFile(of: item)
                        }
                    }
                }
            }
        }
    }
}

extension DownloadsOverviewCard {
    private func openFile(of item: DownloadItem) {
        guard item.state == .completed, let url = item.destinationURL else { return }
        NSWorkspace.shared.open(url)
        onOpen()
    }
}

/// Observes its download, so progress redraws this row alone.
private struct DownloadPreviewRow: View {
    @ObservedObject var item: DownloadItem
    let accent: Color
    let action: () -> Void

    var body: some View {
        OverviewRow(action: action) {
            HStack(spacing: 9) {
                Image(nsImage: item.systemIcon)
                    .resizable()
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.state == .downloading {
                        ProgressView(value: item.progress)
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                            .tint(accent)
                    }
                }
                Spacer(minLength: 4)
                Text(status)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        switch item.state {
        case .downloading: return item.hasKnownSize ? "\(Int(item.progress * 100))%" : item.formattedDownloadedBytes
        case .paused: return "Paused"
        case .completed: return item.formattedFileSize
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

private struct ReadingListOverviewCard: View {
    let accent: Color
    let open: (_ url: String, _ inBackground: Bool) -> Void
    @ObservedObject private var readingList = SafariReadingListManager.shared
    @EnvironmentObject var tabManager: TabManager

    var body: some View {
        let unread = readingList.items.filter(\.isUnread)
        OverviewCard(list: .readingList, trailing: unread.isEmpty ? "" : "\(unread.count) to read", accent: accent) {
            if readingList.items.isEmpty && readingList.permissionState != .granted {
                CardPlaceholder(text: "Shows your Safari Reading List")
            } else if unread.isEmpty {
                CardPlaceholder(text: "Nothing left to read")
            } else {
                ForEach(unread.prefix(2)) { item in
                    OverviewRow(action: { openItem(item, inBackground: false) }) {
                        HStack(spacing: 9) {
                            FaviconView(url: item.url, size: 16)
                            Text(item.title.isEmpty ? item.url : item.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                    }
                    .libraryContextMenu { menu, anchor in
                        SidebarLibraryMenus.addItems(to: menu, for: item, tabManager: tabManager, anchor: anchor) { inBackground in
                            openItem(item, inBackground: inBackground)
                        }
                    }
                }
            }
        }
    }
}

extension ReadingListOverviewCard {
    /// Opened, as from the list, it's read.
    private func openItem(_ item: ReadingListItem, inBackground: Bool) {
        open(item.url, inBackground)
        if item.isUnread {
            Task { try? await readingList.markAs(read: true, url: item.url) }
        }
    }
}

private struct HistoryOverviewCard: View {
    /// The active space's: a separate profile has its own.
    @ObservedObject var history: HistoryManager
    let accent: Color
    let open: (_ url: String, _ inBackground: Bool) -> Void
    @EnvironmentObject var tabManager: TabManager

    var body: some View {
        let recent = history.recentEntries.prefix(3)
        OverviewCard(list: .history, trailing: "All", accent: accent) {
            if recent.isEmpty {
                CardPlaceholder(text: "No history yet")
            } else {
                ForEach(Array(recent)) { entry in
                    OverviewRow(action: { open(entry.url, false) }) {
                        HStack(spacing: 9) {
                            FaviconView(url: entry.url, size: 16)
                            Text(entry.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Self.time(of: entry.visitedAt))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .libraryContextMenu { menu, anchor in
                        SidebarLibraryMenus.addItems(to: menu, for: entry, history: history, tabManager: tabManager, anchor: anchor) { inBackground in
                            open(entry.url, inBackground)
                        }
                    }
                }
            }
        }
    }

    private static func time(of date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.relative(presentation: .named))
    }
}

/// Explore with AI's newest pages
private struct ExploreOverviewCard: View {
    let accent: Color
    let open: (_ url: String, _ inBackground: Bool) -> Void
    @ObservedObject private var library = ExploreLibrary.shared

    var body: some View {
        let collection = library.collection
        OverviewCard(list: .explore, trailing: collection.isEmpty ? "" : "\(collection.count)", accent: accent) {
            if collection.isEmpty {
                CardPlaceholder(text: "Ask about a page from ⌘K")
            } else {
                ForEach(collection.prefix(2)) { answer in
                    OverviewRow(action: { open(answer.pageURL, false) }) {
                        ExploreAnswerLabel(answer: answer, lineLimit: 1)
                    }
                    .contextMenu {
                        ExploreAnswerMenu(answer: answer) { inBackground in
                            open(answer.pageURL, inBackground)
                        }
                    }
                }
            }
        }
    }
}

/// A space in the overview: switches to it.
private struct SpaceCard: View {
    let space: Space
    let isCurrent: Bool
    let tabCount: Int
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    SpaceIconView(icon: space.icon, name: space.name, size: 11)
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 6).fill(space.color.color))
                    Text(space.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 4) {
                    Text(tabCount == 1 ? "1 tab" : "\(tabCount) tabs")
                    if space.usesSeparateProfile {
                        Image(systemName: "person.crop.circle")
                            .help("Has its own profile")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(space.color.color.opacity(isCurrent ? 0.25 : 0.12)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(space.color.color.opacity(isCurrent ? 0.7 : 0), lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.03 : 1)
        .animation(.bouncy(duration: 0.25), value: isHovering)
        .onHover { hovering in
            if isHovering != hovering {
                isHovering = hovering
            }
        }
        .contextMenu {
            SpaceContextMenu(spaceID: space.id)
        }
        .accessibilityLabel(Text(space.name))
    }
}

private struct NewSpaceCard: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("New Space")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(isHovering ? 0.3 : 0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if isHovering != hovering {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Full lists

/// One of the library's lists, all of it, with a header to zoom back out.
struct SidebarLibraryListView: View {
    let list: SidebarLibraryList
    @Environment(SidebarStateManager.self) var sidebarStateManager
    @ObservedObject private var spaceManager = SpaceManager.shared
    @EnvironmentObject private var spaceSelection: SpaceSelection

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                KlarButton.titleBar(action: {
                    sidebarStateManager.show(.overview)
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                }
                .accessibilityLabel(Text("Back to Overview"))
                .help("Back to Overview")

                Image(systemName: list.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(spaceSelection.activeSpace?.color.color ?? .accentColor)
                Text(list.title)
                    .font(.system(size: 13, weight: .semibold))

                if list == .history, let space = spaceSelection.activeSpace, space.usesSeparateProfile {
                    Text("\(space.name) only")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .help("This space has its own profile, with its own history")
                }

                Spacer(minLength: 4)

                if list == .readingList {
                    ReadingListFilterButton()
                }

                if list == .downloads {
                    Button("Show in Finder") {
                        let folder = URL(fileURLWithPath: TOMLSettingsManager.shared.downloadLocation)
                        NSWorkspace.shared.open(folder)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: Self.headerHeight)

            if list == .history {
                // Centered between the header's text, whose baseline is ~13pt
                // above the header's bottom, and the first day's label, ~14pt
                // below the list's top (`SidebarHistoryDayHeaderView`).
                HistorySearchField()
                    .padding(.horizontal, 6)
                    .padding(.top, 3)
                    .padding(.bottom, 2)
            }

            switch list {
            case .downloads:
                SidebarDownloadsAppKitBridge()
            case .readingList:
                SidebarReadingListAppKitBridge()
            case .history:
                SidebarHistoryAppKitBridge()
            case .explore:
                ExploreListView()
            }
        }
        // Its title's capitals where the other levels' content starts
        .padding(.top, SidebarLayoutMetrics.contentEdgeInset - Self.headerTitleTop)
    }

    private static let headerHeight: CGFloat = 36
    /// How far below the header's top its title's capitals start, centered
    /// in it.
    private static let headerTitleTop: CGFloat = {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let baseline = (headerHeight - (font.ascender - font.descender)) / 2 + font.ascender
        return (baseline - font.capHeight).rounded()
    }()
}

/// Shows only the Reading List's unread items, or all of them.
private struct ReadingListFilterButton: View {
    @ObservedObject private var filter = SidebarReadingListFilter.shared
    @ObservedObject private var spaceManager = SpaceManager.shared
    @EnvironmentObject private var spaceSelection: SpaceSelection

    var body: some View {
        let isOn = filter.showsUnreadOnly
        KlarButton.titleBar(action: {
            filter.showsUnreadOnly.toggle()
        }) {
            Image(systemName: isOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 14))
                .foregroundStyle(isOn ? (spaceSelection.activeSpace?.color.color ?? .accentColor) : Color.secondary)
                .frame(width: 16, height: 16)
        }
        .accessibilityLabel(Text("Unread Only"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(isOn ? "Showing unread items only. Click to show all." : "Show unread items only")
    }
}

/// The History list's search, on glass.
private struct HistorySearchField: View {
    @ObservedObject private var search = SidebarHistorySearch.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search History", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear Search"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .onAppear {
            // Each visit starts with the whole history.
            search.query = ""
        }
    }
}

// MARK: - Context menus

extension View {
    /// The menu a library item has in its list (`SidebarLibraryMenus`): an
    /// AppKit menu, built when it opens, with this view for Share… to point from.
    func libraryContextMenu(_ build: @escaping (_ menu: NSMenu, _ anchor: NSView) -> Void) -> some View {
        overlay(LibraryContextMenuArea(build: build))
    }
}

private struct LibraryContextMenuArea: NSViewRepresentable {
    let build: (NSMenu, NSView) -> Void

    func makeNSView(context: Context) -> LibraryContextMenuView {
        let view = LibraryContextMenuView()
        view.build = build
        return view
    }

    func updateNSView(_ view: LibraryContextMenuView, context: Context) {
        view.build = build
    }
}

/// Takes the right clicks and Control-clicks over a SwiftUI row and shows
/// its menu; every other event goes on to the row under it.
final class LibraryContextMenuView: NSView {
    var build: ((NSMenu, NSView) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let isMenuClick: Bool
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            isMenuClick = true
        case .leftMouseDown, .leftMouseUp:
            isMenuClick = event.modifierFlags.contains(.control)
        default:
            isMenuClick = false
        }
        return isMenuClick ? super.hitTest(point) : nil
    }

    // Shown here rather than through `menu(for:)`, as in the lists.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(for: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func showMenu(for event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        build?(menu, self)
        guard !menu.items.isEmpty else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
