import AppKit
import Combine

/// The downloads, newest first. Double-clicking a finished one opens it.
final class SidebarDownloadsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let tabManager: TabManager
    private let downloadManager = DownloadManager.shared

    private(set) var cancellables: Set<AnyCancellable> = []

    private let tableView = SidebarLibraryTableView()
    private lazy var scrollView = tableView.makeScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No Downloads")

    /// What the table shows: the manager's list changes a main-queue hop
    /// before the table reloads, so its rows go by this copy.
    private var downloads: [DownloadItem] = []

    /// Kept by download: rows move as downloads are added and removed.
    private var selectedDownloadID: UUID?

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

        tableView.rowHeight = SidebarDownloadRowView.height
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
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
        downloads = downloadManager.downloads
        downloadManager.$downloads
            .receive(on: DispatchQueue.main)
            .sink { [weak self] downloads in
                guard let self else { return }
                self.downloads = downloads
                self.tableView.reloadData()
                if let id = self.selectedDownloadID, let row = downloads.firstIndex(where: { $0.id == id }) {
                    self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                } else {
                    self.tableView.deselectAll(nil)
                }
                self.emptyLabel.isHidden = !downloads.isEmpty
                self.scrollView.isHidden = downloads.isEmpty
            }
            .store(in: &cancellables)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return downloads.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarLibraryRowView.make(in: tableView)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedDownloadID = row >= 0 && row < downloads.count ? downloads[row].id : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = SidebarDownloadRowView.reuseIdentifier
        let cell: SidebarDownloadRowView
        if let recycled = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarDownloadRowView {
            cell = recycled
        } else {
            cell = SidebarDownloadRowView(frame: .zero)
            cell.identifier = identifier
        }
        cell.configure(with: downloads[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < downloads.count else { return nil }
        let download = downloads[row]
        guard download.state == .completed, let dest = download.destinationURL else { return nil }
        let item = NSPasteboardItem()
        item.setString(dest.absoluteString, forType: .fileURL)
        return item
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < downloads.count else { return }
        open(downloads[row])
    }

    private func open(_ download: DownloadItem) {
        guard download.state == .completed, let url = download.destinationURL else { return }
        NSWorkspace.shared.open(url)
    }
}

extension SidebarDownloadsViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.contextMenuRow
        guard row >= 0, row < downloads.count else { return }
        let download = downloads[row]
        SidebarLibraryMenus.addItems(to: menu, for: download, tabManager: tabManager) { [weak self] in
            self?.open(download)
        }
    }
}
