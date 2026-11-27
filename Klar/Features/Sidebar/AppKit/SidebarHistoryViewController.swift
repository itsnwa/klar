import AppKit
import Combine

/// What the History list is searched for: typed in its header's search
/// field (SwiftUI, on glass), read by `SidebarHistoryViewController`.
final class SidebarHistorySearch: ObservableObject {
    static let shared = SidebarHistorySearch()
    @Published var query = ""
    private init() {}
}

/// All of the active space's history, by day, newest first: loaded a page
/// at a time as it's scrolled, and searchable. A space with a separate
/// profile has a history of its own. Opening an entry stays in the list,
/// with the entry of the active tab highlighted.
final class SidebarHistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let tabManager: TabManager
    private var history: HistoryManager

    private(set) var cancellables: Set<AnyCancellable> = []
    private var historyCancellable: AnyCancellable?

    /// The entries loaded so far (or the search's results).
    private var entries: [HistoryEntryData] = []
    private var hasMorePages = true
    private var isLoadingPage = false
    /// Numbers the loads, so one that lands after a newer one started is dropped.
    private var loadGeneration = 0
    private static let pageSize = 200
    private static let searchLimit = 500

    private let tableView = SidebarLibraryTableView()
    private lazy var scrollView = tableView.makeScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No History")

    private enum Row {
        case header(String)
        case entry(HistoryEntryData)

        /// Shows the same: a row that doesn't is removed and inserted again.
        func looksSame(as other: Row) -> Bool {
            switch (self, other) {
            case let (.header(a), .header(b)):
                return a == b
            case let (.entry(a), .entry(b)):
                return a.url == b.url && a.title == b.title && a.visitedAt == b.visitedAt
            default:
                return false
            }
        }
    }

    private var rows: [Row] = []

    private var highlight = SidebarLibraryHighlight()
    /// An entry just opened, and when: its visit moves it to the top of
    /// today, and the list scrolls to show it there.
    private var revealed: (url: String, openedAt: Date)?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        self.history = tabManager.spaceSelection?.activeHistory ?? SpaceManager.shared.history(forSpace: nil)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        // Day headers scroll with their entries: floating, they cut across
        // the rows going by under them.
        tableView.floatsGroupRows = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleClick)

        let contextMenu = NSMenu()
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self
        tableView.menu = contextMenu

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.isHidden = true

        container.addSubview(scrollView)
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bind()
    }

    private func bind() {
        bindHistory()

        // Another space may have another profile, with its own history, and
        // a space's profile can be turned on or off.
        guard let selection = tabManager.spaceSelection else { return }
        selection.$activeSpaceID.map { _ in () }
            .merge(with: SpaceManager.shared.$spaces.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak selection] _ in
                guard let self, let selection else { return }
                let history = selection.activeHistory
                guard history !== self.history else { return }
                self.history = history
                self.bindHistory()
            }
            .store(in: &cancellables)

        SidebarHistorySearch.shared.$query
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reload()
            }
            .store(in: &cancellables)

        tabManager.activeTabURLPublisher
            .sink { [weak self] active in
                guard let self else { return }
                self.highlight.activeTabID = active.tabID
                self.highlight.activeURL = active.url
                self.applyHighlight()
            }
            .store(in: &cancellables)

        // Load the next page near the end of the list.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadNextPageIfNeeded()
            }
            .store(in: &cancellables)
    }

    /// Follows the history's changes: a visit or a removal is applied to the
    /// entries loaded, anything else fetches them again.
    private func bindHistory() {
        reload()
        historyCancellable = history.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.apply(change)
            }
    }

    private func apply(_ change: HistoryChange) {
        // The search's results are fetched again: it may or may not match.
        guard searchQuery.isEmpty else {
            reload()
            return
        }
        switch change {
        case .visited(let entry):
            entries.removeAll { $0.url == entry.url }
            entries.insert(entry, at: 0)
        case .removed(let url):
            entries.removeAll { $0.url == url }
        case .reloaded:
            reload()
            return
        }
        updateRows(diffing: true)
    }

    private var searchQuery: String {
        SidebarHistorySearch.shared.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The search's results, or the newest page, keeping at least as many
    /// entries as were loaded.
    private func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let history = self.history
        let query = searchQuery
        let count = max(entries.count, Self.pageSize)
        isLoadingPage = true
        Task { @MainActor [weak self] in
            let loaded = query.isEmpty
                ? await history.entries(visitedBefore: nil, limit: count)
                : await history.searchEntries(matching: query, limit: Self.searchLimit)
            guard let self, generation == self.loadGeneration else { return }
            self.isLoadingPage = false
            self.hasMorePages = query.isEmpty && loaded.count >= count
            self.entries = loaded
            self.updateRows(diffing: false)
        }
    }

    private func loadNextPageIfNeeded() {
        guard hasMorePages, !isLoadingPage, searchQuery.isEmpty, let last = entries.last else { return }
        let visible = scrollView.contentView.bounds
        guard visible.maxY > tableView.bounds.height - visible.height else { return }

        isLoadingPage = true
        let generation = loadGeneration
        let history = self.history
        Task { @MainActor [weak self] in
            let page = await history.entries(visitedBefore: last.visitedAt, limit: Self.pageSize)
            guard let self, generation == self.loadGeneration else { return }
            self.isLoadingPage = false
            self.hasMorePages = page.count >= Self.pageSize
            guard !page.isEmpty else { return }
            let known = Set(self.entries.map(\.url))
            self.entries += page.filter { !known.contains($0.url) }
            self.updateRows(diffing: true)
        }
    }

    // Built once: the rows are built again on every page visit that changes them.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = false
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    /// The entries by day, newest first. They come newest first, so a day's
    /// entries are together: the calendar is asked once a day, not per entry.
    private static func rows(for entries: [HistoryEntryData]) -> [Row] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date())

        var rows: [Row] = []
        rows.reserveCapacity(entries.count + 8)
        var day: DateInterval?
        for entry in entries {
            if day.map({ entry.visitedAt >= $0.start && entry.visitedAt < $0.end }) != true,
               let interval = calendar.dateInterval(of: .day, for: entry.visitedAt) {
                day = interval
                let label: String
                if calendar.isDateInToday(interval.start) {
                    label = "Today"
                } else if calendar.isDateInYesterday(interval.start) {
                    label = "Yesterday"
                } else if let weekAgo, interval.start >= weekAgo {
                    label = weekdayFormatter.string(from: interval.start)
                } else {
                    label = dayFormatter.string(from: interval.start)
                }
                rows.append(.header(label))
            }
            rows.append(.entry(entry))
        }
        return rows
    }

    /// Shows `entries`. Diffing changes only the rows that differ, so the
    /// rows on screen aren't configured again: for a visit, which moves one
    /// entry, or a page added at the end. Not for a refetch: diffing two
    /// unrelated lists takes time in proportion to the square of their size.
    private func updateRows(diffing: Bool) {
        let newRows = Self.rows(for: entries)
        guard diffing else {
            rows = newRows
            tableView.reloadData()
            showRowsChanged()
            return
        }
        let difference = newRows.difference(from: rows) { $0.looksSame(as: $1) }
        rows = newRows
        if !difference.isEmpty {
            // Removals at their old positions, then insertions at their new
            // ones, as NSTableView takes them.
            var removed = IndexSet()
            var inserted = IndexSet()
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            tableView.beginUpdates()
            tableView.removeRows(at: removed, withAnimation: [])
            tableView.insertRows(at: inserted, withAnimation: [])
            tableView.endUpdates()
        }
        showRowsChanged()
    }

    private func showRowsChanged() {
        applyHighlight()
        emptyLabel.stringValue = searchQuery.isEmpty ? "No History" : "No Results"
        emptyLabel.isHidden = !rows.isEmpty
        scrollView.isHidden = rows.isEmpty
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return SidebarHistoryDayHeaderView.height
        case .entry: return SidebarHistoryRowView.height
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .entry = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarLibraryRowView.make(in: tableView)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let label):
            let identifier = SidebarHistoryDayHeaderView.reuseIdentifier
            let cell: SidebarHistoryDayHeaderView
            if let recycled = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarHistoryDayHeaderView {
                cell = recycled
            } else {
                cell = SidebarHistoryDayHeaderView(frame: .zero)
                cell.identifier = identifier
            }
            cell.configure(title: label)
            return cell
        case .entry(let entry):
            let identifier = SidebarHistoryRowView.reuseIdentifier
            let cell: SidebarHistoryRowView
            if let recycled = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarHistoryRowView {
                cell = recycled
            } else {
                cell = SidebarHistoryRowView(frame: .zero)
                cell.identifier = identifier
            }
            cell.configure(with: entry)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .entry(let entry) = rows[row], let url = URL(string: entry.url) else { return nil }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .URL)
        item.setString(url.absoluteString, forType: .string)
        return item
    }

    // MARK: - Opening

    /// Opens the entry and stays in the list; ⌘-click opens it in the background.
    @objc private func handleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, case .entry(let entry) = rows[row] else { return }
        open(entry, inBackground: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    private func open(_ entry: HistoryEntryData, inBackground: Bool) {
        let tabID = tabManager.openFromLibrary(url: entry.url, inBackground: inBackground)
        if !inBackground {
            highlight.opened = (tabID: tabID, url: entry.url)
            revealed = (url: entry.url, openedAt: Date())
        }
        applyHighlight()
    }

    /// Selects the entry of the active tab's page, or none.
    private func applyHighlight() {
        let url = highlight.url
        if revealed?.url != url {
            revealed = nil
        }
        let row = url.flatMap { url in
            rows.firstIndex { row in
                if case .entry(let entry) = row { return entry.url == url }
                return false
            }
        }
        guard let row else {
            if tableView.selectedRow >= 0 {
                tableView.deselectAll(nil)
            }
            return
        }
        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        // Once the visit has moved it
        if let revealed, case .entry(let entry) = rows[row], entry.visitedAt >= revealed.openedAt {
            self.revealed = nil
            tableView.scrollRowToVisible(row)
            // With its day's header, when that's right above it
            if row > 0, case .header = rows[row - 1] {
                tableView.scrollRowToVisible(row - 1)
            }
        }
    }

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard case .entry(let entry) = rows[row], edge == .trailing else { return [] }
        let action = NSTableViewRowAction(style: .destructive, title: "Remove") { [weak self] _, _ in
            self?.history.removeEntry(entry)
        }
        return [action]
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.contextMenuRow
        guard row >= 0, row < rows.count, case .entry(let entry) = rows[row],
              let anchor = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        SidebarLibraryMenus.addItems(to: menu, for: entry, history: history, tabManager: tabManager, anchor: anchor) { [weak self] inBackground in
            self?.open(entry, inBackground: inBackground)
        }
    }
}
