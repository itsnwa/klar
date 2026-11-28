import AppKit
import Combine

/// Where the library lists' rows put their content: where a tab row puts
/// its own, inside the same rounded fill inset from the sidebar's edges.
enum SidebarLibraryMetrics {
    /// The row's fill, from the sidebar's edges.
    static let rowInset = SidebarLayoutMetrics.outerHorizontalPadding
    /// A 16pt favicon's leading edge, as in a tab row.
    static let iconLeading = rowInset + 11
    /// After the favicon and a tab row's gap.
    static let titleLeading = iconLeading + 16 + 11
    /// From the trailing edge, inside the fill.
    static let trailing = rowInset + 8
}

/// The table of a library list (Downloads, Reading List, History): its rows
/// are highlighted under the pointer and selected like tab rows. Hover comes
/// from one tracking area over the table, as in `SidebarRowsView`, so it
/// doesn't stick on rows recycled while scrolling.
final class SidebarLibraryTableView: NSTableView {
    private var trackingArea: NSTrackingArea?
    private var hoveredRow = -1
    private var scrollCancellable: AnyCancellable?

    init() {
        super.init(frame: .zero)
        style = .plain
        headerView = nil
        backgroundColor = .clear
        gridStyleMask = []
        intercellSpacing = .zero
        allowsMultipleSelection = false
        allowsEmptySelection = true
        allowsColumnResizing = false
        allowsColumnReordering = false
        usesAutomaticRowHeights = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.minWidth = 100
        column.resizingMask = [.autoresizingMask, .userResizingMask]
        addTableColumn(column)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A scroll view for the table, without a background or the insets a
    /// window's title bar would add, ending like the sidebar's other
    /// content: room at the bottom, above the space bar, and separators at
    /// its edges while there's more of the list past them.
    func makeScrollView() -> NSScrollView {
        // Its top line right under the list's header
        let scrollView = SidebarScrollView(topSeparatorInset: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        // Scrolls without a scroller: its edge separators show there's more
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: SidebarLayoutMetrics.contentBottomInsideSeparator, right: 0)
        scrollView.documentView = self
        return scrollView
    }

    // MARK: - Context menu

    /// The row whose context menu is open, or -1. Read this rather than
    /// `clickedRow`, which only the table's own menu handling sets.
    private(set) var contextMenuRow = -1

    // As in `SidebarRowsView`, the menu is shown here rather than through
    // `menu(for:)`: given it there, the table outlines the clicked row.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(for: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func showContextMenu(for event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let menu else { return }
        contextMenuRow = row
        defer { contextMenuRow = -1 }
        // Built now to find out whether the row has one (History's days don't)
        menu.delegate?.menuNeedsUpdate?(menu)
        guard !menu.items.isEmpty else { return }
        // The row keeps its hover fill while the menu is open.
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        refreshHover()
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === trackingArea else { return super.mouseEntered(with: event) }
        updateHover(atWindowLocation: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(atWindowLocation: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === trackingArea else { return super.mouseExited(with: event) }
        setHoveredRow(-1)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Scrolling moves the rows under a pointer that stays put.
        scrollCancellable = nil
        guard window != nil, let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollCancellable = NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: clipView)
            .sink { [weak self] _ in
                self?.refreshHover()
            }
    }

    override func reloadData() {
        super.reloadData()
        // The row under the pointer may be another item now.
        setHoveredRow(-1)
        refreshHover()
    }

    override func didAdd(_ rowView: NSTableRowView, forRow row: Int) {
        super.didAdd(rowView, forRow: row)
        (rowView as? SidebarLibraryRowView)?.isHovered = row == hoveredRow
    }

    override func didRemove(_ rowView: NSTableRowView, forRow row: Int) {
        super.didRemove(rowView, forRow: row)
        (rowView as? SidebarLibraryRowView)?.isHovered = false
    }

    private func refreshHover() {
        guard let window else { return }
        updateHover(atWindowLocation: window.mouseLocationOutsideOfEventStream)
    }

    private func updateHover(atWindowLocation location: NSPoint) {
        let point = convert(location, from: nil)
        setHoveredRow(visibleRect.contains(point) ? row(at: point) : -1)
    }

    private func setHoveredRow(_ row: Int) {
        guard row != hoveredRow else { return }
        libraryRowView(at: hoveredRow)?.isHovered = false
        hoveredRow = row
        libraryRowView(at: row)?.isHovered = true
    }

    private func libraryRowView(at row: Int) -> SidebarLibraryRowView? {
        guard row >= 0, row < numberOfRows else { return nil }
        return rowView(atRow: row, makeIfNecessary: false) as? SidebarLibraryRowView
    }
}

/// A library list's row: a tab row's rounded fill, faint under the pointer
/// and lighter, with a border, when selected (`SidebarTabRowView.selectedFill`),
/// its cell's text as it is. Group rows (History's days) have none.
final class SidebarLibraryRowView: NSTableRowView {
    private static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarLibraryRowView")

    static func make(in tableView: NSTableView) -> SidebarLibraryRowView {
        if let recycled = tableView.makeView(withIdentifier: reuseIdentifier, owner: nil) as? SidebarLibraryRowView {
            return recycled
        }
        let rowView = SidebarLibraryRowView()
        rowView.identifier = reuseIdentifier
        return rowView
    }

    private let fillView = NSView()

    var isHovered = false {
        didSet {
            if isHovered != oldValue {
                updateFill()
            }
        }
    }

    override var isSelected: Bool {
        didSet { updateFill() }
    }

    override var isGroupRowStyle: Bool {
        didSet { updateFill() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fillView.translatesAutoresizingMaskIntoConstraints = false
        // As in `SidebarTabRowView`: created now, so its actions take.
        fillView.layer = CALayer()
        fillView.wantsLayer = true
        fillView.layer?.actions = ["backgroundColor": NSNull(), "borderColor": NSNull(), "borderWidth": NSNull()]
        fillView.layer?.cornerRadius = 12
        fillView.layer?.cornerCurve = .continuous
        // Below the cell, which the table adds after it.
        addSubview(fillView)
        NSLayoutConstraint.activate([
            fillView.topAnchor.constraint(equalTo: topAnchor),
            fillView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fillView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarLibraryMetrics.rowInset),
            fillView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarLibraryMetrics.rowInset)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The fill is the selection, whether the table is focused or not, and
    // a light one: the cells keep their colors.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        let color: NSColor
        if isGroupRowStyle {
            color = .clear
        } else if isSelected {
            color = SidebarTabRowView.selectedFill
        } else if isHovered {
            color = SidebarTabRowView.hoverFill
        } else {
            color = .clear
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.fillView.layer?.backgroundColor = color.cgColor
            self.fillView.layer?.borderColor = SidebarTabRowView.selectedBorder.cgColor
        }
        fillView.layer?.borderWidth = isSelected && !isGroupRowStyle ? SidebarTabRowView.selectedBorderWidth : 0
    }
}

/// Which item of a library list to highlight: the page in the active tab.
/// An item opened from the list stays highlighted while its tab is active,
/// even once the page has redirected to another address.
struct SidebarLibraryHighlight {
    var activeTabID: UUID?
    var activeURL = ""
    /// The item last opened from the list, and the tab it's in.
    var opened: (tabID: UUID, url: String)?

    var url: String? {
        if let opened, opened.tabID == activeTabID {
            return opened.url
        }
        return activeURL.isEmpty ? nil : activeURL
    }
}

extension TabManager {
    typealias ActiveTabURL = (tabID: UUID?, url: String)

    /// The active tab and its address, as either changes. A locked private
    /// tab's is none (PrivateTabLock): no history row lights up for it.
    var activeTabURLPublisher: AnyPublisher<ActiveTabURL, Never> {
        $activeTabId
            .map { [weak self] id -> AnyPublisher<ActiveTabURL, Never> in
                guard let id, let tab = self?.tabs.first(where: { $0.id == id }) else {
                    return Just<ActiveTabURL>((tabID: nil, url: "")).eraseToAnyPublisher()
                }
                let lockChanges = NotificationCenter.default.publisher(for: .privateTabsLockDidChange)
                    .map { _ in () }
                    .prepend(())
                return tab.$url
                    .combineLatest(lockChanges)
                    .map { [weak tab] url, _ -> ActiveTabURL in (tabID: id, url: tab?.isLocked == true ? "" : url) }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            // `activeTabId` publishes before it's set.
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// Opens a page from a library list: in the active space's tab already
    /// showing it, else in a new tab. In the background, always a new one.
    @discardableResult
    func openFromLibrary(url: String, inBackground: Bool = false) -> UUID {
        if !inBackground {
            if let tab = activeTab, tab.url == url {
                return tab.id
            }
            if let tab = tabs.first(where: { $0.url == url && spaceSelection?.isInActiveSpace($0) != false }) {
                switchToTab(tab)
                return tab.id
            }
        }
        return createNewTab(url: url, activate: !inBackground)
    }
}
