import AppKit
import Combine
import SwiftUI

/// Whether the Reading List shows only what's left to read: toggled in its
/// header (SwiftUI), read by `SidebarReadingListViewController`.
final class SidebarReadingListFilter: ObservableObject {
    static let shared = SidebarReadingListFilter()
    private static let defaultsKey = "readingListShowsUnreadOnly"

    @Published var showsUnreadOnly: Bool {
        didSet { UserDefaults.standard.set(showsUnreadOnly, forKey: Self.defaultsKey) }
    }

    private init() {
        showsUnreadOnly = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }
}

/// Safari's Reading List. Opening an item stays in the list, with the item
/// of the active tab highlighted, and marks it read.
final class SidebarReadingListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let tabManager: TabManager
    private let readingList = SafariReadingListManager.shared
    private let filter = SidebarReadingListFilter.shared

    private(set) var cancellables: Set<AnyCancellable> = []

    private let tableView = SidebarLibraryTableView()
    private lazy var scrollView = tableView.makeScrollView()
    private let emptyStateView = NSHostingView(rootView: ReadingListEmptyStateView(state: .loading))

    /// The items shown: all of them, or the unread ones.
    private var items: [ReadingListItem] = []
    /// Read while the list is open: with only unread items shown, they stay
    /// until the list is left, instead of going as they're opened.
    private var readHere: Set<String> = []
    private var highlight = SidebarLibraryHighlight()

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleClick)

        let contextMenu = NSMenu()
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self
        tableView.menu = contextMenu

        // Sized by the container alone, so the text wraps to the sidebar's width.
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.sizingOptions = []

        container.addSubview(scrollView)
        container.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            emptyStateView.topAnchor.constraint(equalTo: container.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bind()
        Task { await readingList.refresh() }
    }

    private func bind() {
        readingList.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.showItems(items)
            }
            .store(in: &cancellables)

        filter.$showsUnreadOnly
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                // Turned on, it hides everything read.
                self.readHere = []
                // `@Published` sends before it sets.
                DispatchQueue.main.async {
                    self.showItems(self.readingList.items)
                }
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

        readingList.$permissionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateEmptyState()
            }
            .store(in: &cancellables)
    }

    private func showItems(_ all: [ReadingListItem]) {
        items = filter.showsUnreadOnly
            ? all.filter { $0.isUnread || readHere.contains($0.url) }
            : all
        tableView.reloadData()
        applyHighlight()
        updateEmptyState()
    }

    private func updateEmptyState() {
        let state: ReadingListEmptyState?
        switch readingList.permissionState {
        case .unknown:
            state = .loading
        case .denied:
            state = .needsAccess
        case .fileMissing:
            state = .empty
        case .granted:
            if !items.isEmpty {
                state = nil
            } else {
                state = readingList.items.isEmpty ? .empty : .allRead
            }
        }

        if let state {
            if emptyStateView.rootView.state != state {
                emptyStateView.rootView = ReadingListEmptyStateView(state: state)
            }
            emptyStateView.isHidden = false
            scrollView.isHidden = true
        } else {
            emptyStateView.isHidden = true
            scrollView.isHidden = false
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        SidebarReadingListRowView.height(for: items[row])
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarLibraryRowView.make(in: tableView)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = SidebarReadingListRowView.reuseIdentifier
        let cell: SidebarReadingListRowView
        if let recycled = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarReadingListRowView {
            cell = recycled
        } else {
            cell = SidebarReadingListRowView(frame: .zero)
            cell.identifier = identifier
        }
        cell.configure(with: items[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < items.count, let url = URL(string: items[row].url) else { return nil }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .URL)
        item.setString(url.absoluteString, forType: .string)
        return item
    }

    // MARK: - Opening

    /// Opens the item and stays in the list; ⌘-click opens it in the background.
    @objc private func handleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        open(items[row], inBackground: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    private func open(_ item: ReadingListItem, inBackground: Bool) {
        let tabID = tabManager.openFromLibrary(url: item.url, inBackground: inBackground)
        if !inBackground {
            highlight.opened = (tabID: tabID, url: item.url)
        }
        applyHighlight()
        if item.isUnread {
            readHere.insert(item.url)
            Task { try? await readingList.markAs(read: true, url: item.url) }
        }
    }

    /// Selects the item of the active tab's page, or none.
    private func applyHighlight() {
        guard let url = highlight.url, let row = items.firstIndex(where: { $0.url == url }) else {
            if tableView.selectedRow >= 0 {
                tableView.deselectAll(nil)
            }
            return
        }
        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // MARK: - Context menu

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard row >= 0, row < items.count, edge == .trailing else { return [] }
        let item = items[row]
        let action = NSTableViewRowAction(style: .destructive, title: "Remove") { [weak self] _, _ in
            Task { @MainActor in self?.remove(item) }
        }
        return [action]
    }

    // The list shows it succeeding, so only a failure gets a toast.
    private func remove(_ item: ReadingListItem) {
        Task {
            do {
                try await readingList.removeFromReadingList(url: item.url)
            } catch {
                SafariReadingListManager.reportFailure(error, to: tabManager.toastManager)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.contextMenuRow
        guard row >= 0, row < items.count,
              let anchor = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        let item = items[row]
        SidebarLibraryMenus.addItems(to: menu, for: item, tabManager: tabManager, anchor: anchor) { [weak self] inBackground in
            self?.open(item, inBackground: inBackground)
        }
    }
}

// MARK: - Empty state

private enum ReadingListEmptyState: Equatable {
    case loading
    case needsAccess
    case empty
    /// Only unread items shown, and there are none.
    case allRead
}

private struct ReadingListEmptyStateView: View {
    let state: ReadingListEmptyState

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .needsAccess:
            ContentUnavailableView {
                Label("Full Disk Access Needed", systemImage: "lock")
            } description: {
                Text("Safari keeps its Reading List in a protected folder. Allow Klar under Privacy & Security › Full Disk Access to show it here.")
            } actions: {
                Button("Open System Settings", action: openFullDiskAccessSettings)
            }
        case .empty:
            ContentUnavailableView(
                "No Reading List Items",
                systemImage: "eyeglasses",
                description: Text("Add pages from a tab's context menu or the command palette.")
            )
        case .allRead:
            ContentUnavailableView {
                Label("All Read", systemImage: "checkmark.circle")
            } description: {
                Text("Pages you've read are hidden.")
            } actions: {
                Button("Show All") {
                    SidebarReadingListFilter.shared.showsUnreadOnly = false
                }
            }
        }
    }

    private func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
