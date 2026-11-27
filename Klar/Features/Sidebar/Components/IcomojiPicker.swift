import SwiftUI
import AppKit

/// What the icomoji picker picked: an icomoji, or (for a space) the first
/// letter of its name.
nonisolated enum IcomojiChoice: Hashable {
    case letter
    case icomoji(Icomoji)
}

/// Picks the icon of a folder or a space, on pages for SF Symbols, emoji and
/// Klar's own icons — and, for a space, the first letter of its name. Each
/// page is in groups, with the ones picked lately first and a bar at the
/// bottom that jumps to a group; the search looks through every page, and an
/// emoji typed into it is offered as it is, so any emoji works, skin tones
/// too. A tile beside the search shows the choice under the pointer (or the
/// arrow keys, from the search; Return picks it) as it would look.
struct IcomojiPicker: View {
    let selection: IcomojiChoice?
    /// A space's letter, offered on a page of its own; nil for a folder.
    var letter: String? = nil
    var tint: Color = .accentColor
    let onSelect: (IcomojiChoice) -> Void

    static let size = CGSize(width: IcomojiGrid.width + 2 * horizontalInset, height: 412)
    private static let horizontalInset: CGFloat = 12

    @Environment(\.dismiss) private var dismiss
    @State private var page: Page
    @State private var searchText = ""
    @State private var grid: IcomojiGrid
    @State private var cursor = IcomojiCursor()
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var currentSectionID: String?
    /// Set while scrolling to a group from the bar, which then stays lit even
    /// if the list can't scroll it all the way up.
    @State private var jumpTarget: String?
    @State private var recents: [Icomoji]
    @FocusState private var isSearchFocused: Bool
    @Namespace private var pageTabsNamespace

    private enum Page: CaseIterable, Identifiable {
        case letter
        case symbols
        case emoji
        case icons

        var id: Self { self }

        var title: String {
            switch self {
            case .letter: return "Letter"
            case .symbols: return "Symbols"
            case .emoji: return "Emoji"
            case .icons: return "Icons"
            }
        }

        var kind: Icomoji.Kind {
            switch self {
            case .letter, .symbols: return .symbol
            case .emoji: return .emoji
            case .icons: return .custom
            }
        }
    }

    init(selection: IcomojiChoice?, letter: String? = nil, tint: Color = .accentColor, onSelect: @escaping (IcomojiChoice) -> Void) {
        self.selection = selection
        self.letter = letter
        self.tint = tint
        self.onSelect = onSelect

        let page: Page
        switch selection {
        case .letter: page = letter == nil ? .symbols : .letter
        case .icomoji(.emoji): page = .emoji
        case .icomoji(.custom): page = .icons
        case .icomoji(.symbol), nil: page = .symbols
        }
        let recents = Icomoji.recents
        _page = State(initialValue: page)
        _recents = State(initialValue: recents)
        _grid = State(initialValue: IcomojiGrid(kind: page.kind, recents: recents))
    }

    private var pages: [Page] {
        letter == nil ? [.symbols, .emoji, .icons] : Page.allCases
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Spaces show their icon on their color; folders show it as it is.
    private var showsOnTint: Bool { letter != nil }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !isSearching {
                pageTabs
                    .padding(.horizontal, Self.horizontalInset)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }

            if page == .letter && !isSearching {
                letterPage
            } else {
                list
                if !isSearching {
                    sectionBar
                        .transition(.opacity)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.snappy(duration: 0.2), value: isSearching)
        .onAppear {
            focusSearch()
        }
        .onChange(of: page) { _, _ in
            rebuildGrid()
            focusSearch()
        }
        .onChange(of: searchText) { _, _ in
            rebuildGrid()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            IcomojiPreview(cursor: cursor, selection: selection, letter: letter, tint: tint, showsOnTint: showsOnTint)
            searchField
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search, or type an emoji", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isSearchFocused)
                .onSubmit(pickHighlighted)
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                    moveCursor(press.key) ? .handled : .ignored
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear Search"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: IcomojiPreview.size)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    /// The pages, the one shown on a capsule that slides to the next.
    private var pageTabs: some View {
        HStack(spacing: 0) {
            ForEach(pages) { item in
                let isCurrent = item == page
                Button {
                    page = item
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background {
                            if isCurrent {
                                Capsule()
                                    .fill(Color.primary.opacity(0.1))
                                    .matchedGeometryEffect(id: "page", in: pageTabsNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .animation(.snappy(duration: 0.25), value: page)
    }

    // MARK: - Pages

    private var letterPage: some View {
        let isSelected = selection == .letter
        return VStack(spacing: 16) {
            Spacer()
            Button {
                select(.letter)
            } label: {
                Text(letter ?? "")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(width: 88, height: 88)
                    .background(
                        RoundedRectangle(cornerRadius: 22)
                            .fill(isSelected ? tint : Color.primary.opacity(0.08))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 22))
            }
            .buttonStyle(IcomojiCellButtonStyle())
            .accessibilityLabel(Text("The first letter of the name"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Text("The first letter of the space’s name, which follows it when you rename the space.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        let grid = self.grid
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(grid.rows) { row in
                    switch row.content {
                    case .header(let title):
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .frame(height: IcomojiGrid.headerHeight)
                    case .cells(let cells):
                        HStack(spacing: 0) {
                            ForEach(cells) { cell in
                                IcomojiCellView(
                                    cell: cell,
                                    letter: letter,
                                    isSelected: cell.choice == selection,
                                    tint: tint,
                                    cursor: cursor,
                                    action: select
                                )
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: IcomojiGrid.rowHeight)
                    }
                }
            }
            .padding(.horizontal, Self.horizontalInset)
            .padding(.bottom, IcomojiGrid.bottomInset)
        }
        .scrollPosition($scrollPosition)
        .scrollIndicators(.automatic)
        .mask(edgeFade)
        .onScrollGeometryChange(for: CGRect.self) { geometry in
            geometry.visibleRect
        } action: { _, rect in
            cursor.visibleRect = rect
        }
        .onScrollGeometryChange(for: String?.self) { geometry in
            grid.sectionID(at: geometry.visibleRect.minY)
        } action: { _, sectionID in
            guard jumpTarget == nil else { return }
            currentSectionID = sectionID
        }
        .overlay {
            if grid.rows.isEmpty {
                VStack(spacing: 4) {
                    Text("No Results")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Try another word, or type an emoji.")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Fades the list out under the page picker and the bar.
    private var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 8)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 8)
        }
    }

    /// A button per group, which scrolls to it; the group in view is lit.
    private var sectionBar: some View {
        HStack(spacing: 0) {
            ForEach(grid.sections) { section in
                let isCurrent = section.id == (currentSectionID ?? grid.sections.first?.id)
                Button {
                    jump(to: section)
                } label: {
                    Image(systemName: section.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(isCurrent ? 0.1 : 0)))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(section.title)
                .accessibilityLabel(Text(section.title))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.15), value: currentSectionID)
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func rebuildGrid() {
        grid = IcomojiGrid(kind: page.kind, recents: recents, query: searchText)
        // Searching starts at the best match, so Return picks it.
        cursor.cell = isSearching ? grid.firstCell : nil
        currentSectionID = grid.sections.first?.id
        jumpTarget = nil
        scrollPosition.scrollTo(edge: .top)
    }

    private func jump(to section: IcomojiGrid.Section) {
        guard let top = grid.top(of: section.id) else { return }
        currentSectionID = section.id
        jumpTarget = section.id
        withAnimation(.smooth(duration: 0.3)) {
            scrollPosition.scrollTo(y: top)
        } completion: {
            if jumpTarget == section.id {
                jumpTarget = nil
            }
        }
    }

    /// Moves the highlight with an arrow key typed in the search: left and
    /// right through the choices, up and down a row.
    private func moveCursor(_ key: KeyEquivalent) -> Bool {
        guard page != .letter || isSearching, let first = grid.firstCell else { return false }
        guard let current = cursor.cell else {
            // Not while editing the search: only down starts the highlight.
            guard key == .downArrow else { return false }
            cursor.cell = first
            scrollIntoView(first)
            return true
        }
        let next: IcomojiGrid.Cell?
        switch key {
        case .leftArrow: next = grid.cell(before: current)
        case .rightArrow: next = grid.cell(after: current)
        case .upArrow: next = grid.cell(above: current)
        case .downArrow: next = grid.cell(below: current)
        default: return false
        }
        if let next {
            cursor.cell = next
            scrollIntoView(next)
        } else if key == .upArrow {
            // Up from the top row goes back to the search.
            cursor.cell = nil
            scrollPosition.scrollTo(edge: .top)
        }
        return true
    }

    private func scrollIntoView(_ cell: IcomojiGrid.Cell) {
        guard let frame = grid.frame(of: cell) else { return }
        let visible = cursor.visibleRect
        guard visible.height > 0 else { return }
        if frame.minY < visible.minY {
            scrollPosition.scrollTo(y: max(0, frame.minY))
        } else if frame.maxY > visible.maxY {
            scrollPosition.scrollTo(y: frame.maxY - visible.height + IcomojiGrid.bottomInset)
        }
    }

    private func pickHighlighted() {
        if let cell = cursor.cell ?? (isSearching ? grid.firstCell : nil) {
            select(cell.choice)
        }
    }

    private func focusSearch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isSearchFocused = true
        }
    }

    private func select(_ choice: IcomojiChoice) {
        if case .icomoji(let icomoji) = choice {
            Icomoji.addRecent(icomoji)
        }
        onSelect(choice)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            dismiss()
        }
    }
}

// MARK: - Grid

/// The picker's list: its groups laid out as rows of fixed height, so where
/// each group and choice is in it is known without measuring.
struct IcomojiGrid {
    static let columns = 8
    static let cellSize: CGFloat = 35
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = cellSize
    static let bottomInset: CGFloat = 8
    static var width: CGFloat { CGFloat(columns) * cellSize }

    /// A choice in a group; the same choice can be in two (Recently Used).
    struct Cell: Hashable, Identifiable {
        let sectionID: String
        let choice: IcomojiChoice
        let name: String
        var id: Self { self }
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let cells: [Cell]
    }

    struct Row: Identifiable {
        enum Content {
            case header(String)
            case cells([Cell])
        }
        let id: String
        let content: Content
        let top: CGFloat
        var height: CGFloat {
            if case .header = content { return IcomojiGrid.headerHeight }
            return IcomojiGrid.rowHeight
        }
    }

    let sections: [Section]
    let rows: [Row]
    private let sectionTops: [(id: String, top: CGFloat)]
    /// Each cell's row and column.
    private let positions: [Cell: (row: Int, column: Int)]

    var firstCell: Cell? { sections.first?.cells.first }

    init(kind: Icomoji.Kind, recents: [Icomoji], query: String = "") {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        sections = query.isEmpty
            ? Self.browsingSections(kind: kind, recents: recents)
            : Self.searchSections(query: query, firstKind: kind)

        var rows: [Row] = []
        var sectionTops: [(id: String, top: CGFloat)] = []
        var positions: [Cell: (row: Int, column: Int)] = [:]
        var top: CGFloat = 0
        for section in sections {
            sectionTops.append((section.id, top))
            rows.append(Row(id: "header-\(section.id)", content: .header(section.title), top: top))
            top += Self.headerHeight
            for (index, start) in stride(from: 0, to: section.cells.count, by: Self.columns).enumerated() {
                let cells = Array(section.cells[start..<min(start + Self.columns, section.cells.count)])
                for (column, cell) in cells.enumerated() {
                    positions[cell] = (rows.count, column)
                }
                rows.append(Row(id: "\(section.id)-\(index)", content: .cells(cells), top: top))
                top += Self.rowHeight
            }
        }
        self.rows = rows
        self.sectionTops = sectionTops
        self.positions = positions
    }

    private static func browsingSections(kind: Icomoji.Kind, recents: [Icomoji]) -> [Section] {
        var sections: [Section] = []
        let recent = recents.filter { $0.kind == kind }.prefix(Self.columns * 2)
        if !recent.isEmpty {
            let id = "recent"
            sections.append(Section(id: id, title: "Recently Used", symbol: "clock", cells: recent.map {
                Cell(sectionID: id, choice: .icomoji($0), name: $0.item.name)
            }))
        }
        for category in Icomoji.categories(of: kind) {
            sections.append(Section(id: category.id, title: category.title, symbol: category.symbol, cells: category.items.map {
                Cell(sectionID: category.id, choice: .icomoji($0.icomoji), name: $0.name)
            }))
        }
        return sections
    }

    /// Matches on every page, the page shown first: choices whose name
    /// starts with what's typed, then the others with every word in them.
    private static func searchSections(query: String, firstKind: Icomoji.Kind) -> [Section] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        // An emoji typed or pasted, which may not be in the catalog
        // (one with a skin tone).
        let typedEmoji: Icomoji? = query.first.flatMap { first in
            first.unicodeScalars.contains(where: { !$0.isASCII }) ? .emoji(String(first)) : nil
        }

        let kinds = [firstKind] + Icomoji.Kind.allCases.filter { $0 != firstKind }
        return kinds.compactMap { kind -> Section? in
            let items = Icomoji.categories(of: kind).flatMap(\.items)
            var leading: [IcomojiItem] = []
            var others: [IcomojiItem] = []
            for item in items where words.allSatisfy(item.searchText.contains) {
                if item.name.lowercased().hasPrefix(words[0]) {
                    leading.append(item)
                } else {
                    others.append(item)
                }
            }
            var matches = (leading + others).map(\.icomoji)
            if kind == .emoji, let typedEmoji {
                matches.removeAll { $0 == typedEmoji }
                matches.insert(typedEmoji, at: 0)
            }
            guard !matches.isEmpty else { return nil }
            let (id, title): (String, String) = switch kind {
            case .symbol: ("symbols", "Symbols")
            case .emoji: ("emoji", "Emoji")
            case .custom: ("icons", "Icons")
            }
            return Section(id: id, title: title, symbol: "magnifyingglass", cells: matches.map {
                Cell(sectionID: id, choice: .icomoji($0), name: $0.item.name)
            })
        }
    }

    func top(of sectionID: String) -> CGFloat? {
        sectionTops.first { $0.id == sectionID }?.top
    }

    /// The group at the top of the list scrolled to `offset`.
    func sectionID(at offset: CGFloat) -> String? {
        // A group counts once its header has scrolled mostly away.
        let line = offset + Self.headerHeight / 2
        return sectionTops.last { $0.top <= line }?.id ?? sectionTops.first?.id
    }

    func frame(of cell: Cell) -> CGRect? {
        guard let position = positions[cell] else { return nil }
        var top = rows[position.row].top
        // A group's first row brings its header along.
        if position.row > 0, case .header = rows[position.row - 1].content {
            top = rows[position.row - 1].top
        }
        let bottom = rows[position.row].top + Self.rowHeight
        return CGRect(x: CGFloat(position.column) * Self.cellSize, y: top, width: Self.cellSize, height: bottom - top)
    }

    func cell(before cell: Cell) -> Cell? {
        guard let position = positions[cell] else { return nil }
        if position.column > 0, case .cells(let cells) = rows[position.row].content {
            return cells[position.column - 1]
        }
        return lastCell(inRowBefore: position.row)
    }

    func cell(after cell: Cell) -> Cell? {
        guard let position = positions[cell] else { return nil }
        if case .cells(let cells) = rows[position.row].content, position.column + 1 < cells.count {
            return cells[position.column + 1]
        }
        return cells(inRowAfter: position.row)?.first
    }

    func cell(above cell: Cell) -> Cell? {
        guard let position = positions[cell] else { return nil }
        var row = position.row - 1
        while row >= 0 {
            if case .cells(let cells) = rows[row].content {
                return cells[min(position.column, cells.count - 1)]
            }
            row -= 1
        }
        return nil
    }

    func cell(below cell: Cell) -> Cell? {
        guard let position = positions[cell] else { return nil }
        guard let cells = cells(inRowAfter: position.row) else { return nil }
        return cells[min(position.column, cells.count - 1)]
    }

    private func lastCell(inRowBefore row: Int) -> Cell? {
        var row = row - 1
        while row >= 0 {
            if case .cells(let cells) = rows[row].content { return cells.last }
            row -= 1
        }
        return nil
    }

    private func cells(inRowAfter row: Int) -> [Cell]? {
        var row = row + 1
        while row < rows.count {
            if case .cells(let cells) = rows[row].content { return cells }
            row += 1
        }
        return nil
    }
}

/// The choice highlighted by the pointer or the arrow keys. Its own object,
/// so moving it redraws the cells and the preview, not the whole picker.
@Observable
private final class IcomojiCursor {
    var cell: IcomojiGrid.Cell?
    /// The list's visible part, for scrolling the highlight into view.
    @ObservationIgnored var visibleRect: CGRect = .zero
}

// MARK: - Views

/// The tile beside the search: the highlighted choice, else the current one,
/// as it would look.
private struct IcomojiPreview: View {
    static let size: CGFloat = 28

    let cursor: IcomojiCursor
    let selection: IcomojiChoice?
    let letter: String?
    let tint: Color
    let showsOnTint: Bool

    var body: some View {
        let choice = cursor.cell?.choice ?? selection
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(showsOnTint ? tint : Color.primary.opacity(0.08))
            if let choice {
                IcomojiGlyph(choice: choice, letter: letter, scale: 0.9)
                    .foregroundStyle(showsOnTint ? Color.white : Color.primary)
                    .id(choice)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: Self.size, height: Self.size)
        .animation(.snappy(duration: 0.18, extraBounce: 0.15), value: choice)
        .accessibilityHidden(true)
    }
}

/// One choice in the list: a bare glyph, on a soft fill while highlighted
/// and on the tint once picked.
private struct IcomojiCellView: View {
    let cell: IcomojiGrid.Cell
    let letter: String?
    let isSelected: Bool
    let tint: Color
    let cursor: IcomojiCursor
    let action: (IcomojiChoice) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isHighlighted = cursor.cell == cell
        Button {
            action(cell.choice)
        } label: {
            IcomojiGlyph(choice: cell.choice, letter: letter)
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(isHighlighted ? 1 : 0.75))
                .scaleEffect(isHighlighted && !reduceMotion ? 1.15 : 1)
                .frame(width: IcomojiGrid.cellSize - 4, height: IcomojiGrid.cellSize - 4)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isSelected ? tint : Color.primary.opacity(isHighlighted ? 0.1 : 0))
                )
                .animation(.snappy(duration: 0.15), value: isHighlighted)
                .frame(width: IcomojiGrid.cellSize, height: IcomojiGrid.cellSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(IcomojiCellButtonStyle())
        .help(cell.name)
        .accessibilityLabel(Text(cell.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering in
            if hovering {
                if cursor.cell != cell { cursor.cell = cell }
            } else if cursor.cell == cell {
                cursor.cell = nil
            }
        }
    }
}

/// Presses in a little.
private struct IcomojiCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// A choice's glyph at the list's size: emoji larger than symbols, which
/// fill more of their box.
private struct IcomojiGlyph: View {
    let choice: IcomojiChoice
    let letter: String?
    var scale: CGFloat = 1

    var body: some View {
        switch choice {
        case .letter:
            Text(letter ?? "A")
                .font(.system(size: 15 * scale, weight: .semibold, design: .rounded))
        case .icomoji(let icomoji):
            switch icomoji {
            case .emoji: IcomojiView(icomoji: icomoji, size: 19 * scale)
            case .symbol, .custom: IcomojiView(icomoji: icomoji, size: 15 * scale)
            }
        }
    }
}
