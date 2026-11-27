import SwiftUI

/// An AI answer's Markdown, block by block. Each block's view only runs again
/// when that block changes, so a streaming answer redraws its last block, not
/// the whole answer.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    /// The width the answer has, which a table fits its columns to
    let width: CGFloat
    let passage: PassageFind?
    let showQuote: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                MarkdownBlockView(
                    block: block,
                    width: width,
                    passageStatus: passage?.blockID == block.id ? passage?.status : nil,
                    showQuote: showQuote
                )
                    .equatable()
                    .padding(.top, block.id == 0 ? 0 : Self.spacing(after: blocks[block.id - 1].kind, before: block.kind))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private static func spacing(after previous: MarkdownBlock.Kind, before next: MarkdownBlock.Kind) -> CGFloat {
        switch (previous, next) {
        case (_, .heading(let level, _)):
            return level <= 2 ? 18 : 14
        case (.heading, _):
            return 6
        case (.listItem, .listItem):
            return 5
        default:
            return 11
        }
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let width: CGFloat
    let passageStatus: PassageFind.Status?
    let showQuote: ((Int) -> Void)?

    static func == (lhs: MarkdownBlockView, rhs: MarkdownBlockView) -> Bool {
        guard lhs.block == rhs.block, lhs.width == rhs.width else { return false }
        if case .quote = lhs.block.kind {
            return lhs.passageStatus == rhs.passageStatus && (lhs.showQuote == nil) == (rhs.showQuote == nil)
        }
        return true
    }

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(MarkdownStyle.inline(text, size: MarkdownStyle.headingSize(level)))
                .font(.system(size: MarkdownStyle.headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .foregroundStyle(level <= 3 ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            Text(MarkdownStyle.inline(text, size: MarkdownStyle.bodySize))
                .font(.system(size: MarkdownStyle.bodySize))
                .lineSpacing(MarkdownStyle.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)

        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                ListMarkerView(marker: marker, depth: depth)
                Text(MarkdownStyle.inline(text, size: MarkdownStyle.bodySize))
                    .font(.system(size: MarkdownStyle.bodySize))
                    .strikethrough(marker == .task(isDone: true), color: .secondary)
                    .foregroundStyle(marker == .task(isDone: true) ? Color.secondary : Color.primary)
                    .lineSpacing(MarkdownStyle.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(min(depth, 4)) * 18)

        case .quote(let text):
            quote(text)

        case .code(let language, let text):
            MarkdownCodeBlockView(language: language, code: text)

        case .table(let table):
            MarkdownTableView(table: table, width: width)

        case .divider:
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func quote(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MarkdownStyle.inline(text, size: MarkdownStyle.bodySize))
                .font(.system(size: MarkdownStyle.bodySize))
                .lineSpacing(MarkdownStyle.lineSpacing)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let showQuote {
                let isSearching = passageStatus == .searching
                Button {
                    showQuote(block.id)
                } label: {
                    Label(isSearching ? "Finding on page…" : "Show on page", systemImage: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.link)
                .disabled(isSearching)

                if passageStatus == .notFound {
                    quoteFeedback("Couldn’t find this passage on the page.")
                } else if passageStatus == .differentPage {
                    quoteFeedback("This passage is from a different page.")
                }
            }
        }
        .padding(.leading, 13)
        .background(alignment: .leading) {
            Capsule()
                .fill(.tint.opacity(0.55))
                .frame(width: 3)
        }
    }

    private func quoteFeedback(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ListMarkerView: View {
    let marker: MarkdownListMarker
    let depth: Int

    var body: some View {
        switch marker {
        case .bullet:
            Text(["•", "◦", "▪︎"][depth % 3])
                .font(.system(size: MarkdownStyle.bodySize, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 10)
        case .number(let number):
            Text("\(number).")
                .font(.system(size: MarkdownStyle.bodySize).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
        case .task(let isDone):
            Text(Image(systemName: isDone ? "checkmark.circle.fill" : "circle"))
                .font(.system(size: MarkdownStyle.bodySize))
                .foregroundStyle(isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(minWidth: 16)
        }
    }
}

/// The answer's type: sizes, and inline code and links styled within a line.
enum MarkdownStyle {
    static let bodySize: CGFloat = 13
    static let lineSpacing: CGFloat = 3

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 17
        case 2: return 15
        default: return 13
        }
    }

    /// Inline code on a tint, a point smaller in a monospaced face
    static func inline(_ text: String, size: CGFloat) -> AttributedString {
        var attributed = MarkdownInline.parse(text)
        let codeRanges = attributed.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)
        for range in codeRanges {
            attributed[range].font = Font.system(size: size - 1, design: .monospaced)
            attributed[range].backgroundColor = Color.primary.opacity(0.08)
        }
        return attributed
    }
}

// MARK: - Code

private struct MarkdownCodeBlockView: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "Code" : language)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: code, title: "Copy")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 28)
            .background(Color.primary.opacity(0.04))

            ScrollView(.horizontal) {
                Text(CodeHighlighter.highlight(code, language: language))
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

/// Copies text, and says so for a moment.
struct CopyButton: View {
    let text: String
    /// Shown beside the symbol; nil for the symbol alone
    var title: String?
    @State private var hasCopied = false
    @State private var isHovered = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hasCopied = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                if let title {
                    Text(hasCopied ? "Copied" : title)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 22)
            .background(Color.primary.opacity(isHovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hasCopied ? "Copied" : "Copy")
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
        .task(id: hasCopied) {
            guard hasCopied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            hasCopied = false
        }
    }
}

/// Light syntax colors in Xcode's default theme: comments, strings, numbers,
/// keywords and type names, for the languages answers use most. Others get
/// strings, numbers and C-style comments.
enum CodeHighlighter {
    private enum Family {
        case swift, javaScript, python, ruby, go, rust, cLike, shell, sql, json, yaml, css, markup, plain
    }

    private static func family(of language: String) -> Family {
        switch language.lowercased() {
        case "swift": return .swift
        case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx": return .javaScript
        case "py", "python", "python3": return .python
        case "rb", "ruby": return .ruby
        case "go", "golang": return .go
        case "rs", "rust": return .rust
        case "c", "h", "cpp", "c++", "cc", "hpp", "objc", "objective-c", "m", "mm", "java", "kotlin", "kt", "cs", "csharp", "c#", "scala", "dart", "php":
            return .cLike
        case "sh", "bash", "zsh", "shell", "console", "terminal", "fish": return .shell
        case "sql", "postgresql", "postgres", "mysql", "sqlite": return .sql
        case "json", "jsonc", "json5": return .json
        case "yaml", "yml", "toml", "ini": return .yaml
        case "css", "scss", "sass", "less": return .css
        case "html", "xml", "svg", "vue", "plist": return .markup
        default: return .plain
        }
    }

    private static let keywords: [Family: Set<String>] = [
        .swift: ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "convenience", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet", "didSet"],
        .javaScript: ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "null", "of", "private", "protected", "public", "readonly", "return", "set", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield"],
        .python: ["and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "None", "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield"],
        .ruby: ["alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "raise", "require", "rescue", "return", "self", "super", "then", "true", "unless", "until", "when", "while", "yield"],
        .go: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select", "struct", "switch", "true", "type", "var"],
        .rust: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"],
        .cLike: ["abstract", "auto", "bool", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "delete", "do", "double", "else", "enum", "extends", "extern", "false", "final", "finally", "float", "for", "fun", "goto", "if", "implements", "import", "int", "interface", "long", "namespace", "new", "null", "nullptr", "object", "override", "package", "private", "protected", "public", "return", "short", "signed", "sizeof", "static", "string", "struct", "super", "switch", "template", "this", "throw", "throws", "true", "try", "typedef", "typename", "union", "unsigned", "using", "val", "var", "virtual", "void", "volatile", "when", "while"],
        .shell: ["alias", "case", "cd", "do", "done", "echo", "elif", "else", "esac", "exit", "export", "fi", "for", "function", "if", "in", "local", "return", "set", "source", "sudo", "then", "unset", "until", "while"],
        .sql: ["add", "all", "alter", "and", "as", "asc", "between", "by", "case", "create", "default", "delete", "desc", "distinct", "drop", "else", "end", "exists", "foreign", "from", "group", "having", "in", "index", "inner", "insert", "into", "is", "join", "key", "left", "like", "limit", "not", "null", "offset", "on", "or", "order", "outer", "primary", "references", "right", "select", "set", "table", "then", "union", "update", "values", "when", "where", "with"],
        .json: ["true", "false", "null"],
        .yaml: ["true", "false", "null", "yes", "no"],
    ]

    /// Type names (capitalized) are colored in these
    private static let typedFamilies: Set<Family> = [.swift, .javaScript, .go, .rust, .cLike]

    private static func lineComment(_ family: Family) -> String? {
        switch family {
        case .python, .ruby, .shell, .yaml: return "#"
        case .sql: return "--"
        case .css, .json, .markup: return nil
        default: return "//"
        }
    }

    private static func blockComment(_ family: Family) -> (open: String, close: String)? {
        switch family {
        case .python, .ruby, .shell, .yaml, .json: return nil
        case .markup: return ("<!--", "-->")
        default: return ("/*", "*/")
        }
    }

    private static func quotes(_ family: Family) -> Set<Character> {
        switch family {
        case .swift: return ["\""]
        case .rust: return ["\""]
        case .javaScript, .go, .shell: return ["\"", "'", "`"]
        default: return ["\"", "'"]
        }
    }

    static func highlight(_ code: String, language: String) -> AttributedString {
        let family = family(of: language)
        let keywords = keywords[family] ?? []
        let isCaseInsensitive = family == .sql
        let lineComment = lineComment(family).map(Array.init)
        let blockComment = blockComment(family).map { (Array($0.open), Array($0.close)) }
        let quotes = quotes(family)

        let characters = Array(code)
        var result = AttributedString()
        var plain = ""
        func flushPlain() {
            if !plain.isEmpty {
                result.append(AttributedString(plain))
                plain = ""
            }
        }
        func add(_ range: Range<Int>, _ color: Color) {
            flushPlain()
            var token = AttributedString(String(characters[range]))
            token.foregroundColor = color
            result.append(token)
        }
        func starts(with marker: [Character], at index: Int) -> Bool {
            index + marker.count <= characters.count && Array(characters[index..<index + marker.count]) == marker
        }
        func isIdentifier(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]

            if let lineComment, starts(with: lineComment, at: index) {
                var end = index
                while end < characters.count, characters[end] != "\n" { end += 1 }
                add(index..<end, Palette.comment)
                index = end
                continue
            }

            if let (open, close) = blockComment, starts(with: open, at: index) {
                var end = index + open.count
                while end < characters.count, !starts(with: close, at: end) { end += 1 }
                end = min(end + close.count, characters.count)
                add(index..<end, Palette.comment)
                index = end
                continue
            }

            if quotes.contains(character) {
                var end = index + 1
                while end < characters.count, characters[end] != character {
                    // A quote other than a backtick ends at the line
                    if characters[end] == "\n", character != "`" { break }
                    end += characters[end] == "\\" ? 2 : 1
                }
                end = min(end + 1, characters.count)
                add(index..<end, Palette.string)
                index = end
                continue
            }

            if character.isNumber, index == 0 || !isIdentifier(characters[index - 1]) {
                var end = index + 1
                while end < characters.count, isIdentifier(characters[end]) || characters[end] == "." && end + 1 < characters.count && characters[end + 1].isNumber {
                    end += 1
                }
                add(index..<end, Palette.number)
                index = end
                continue
            }

            if character.isLetter || character == "_" || character == "@" && family == .swift {
                var end = index + 1
                while end < characters.count, isIdentifier(characters[end]) { end += 1 }
                let word = String(characters[index..<end])
                if character == "@" || keywords.contains(isCaseInsensitive ? word.lowercased() : word) {
                    add(index..<end, Palette.keyword)
                } else if typedFamilies.contains(family), character.isUppercase {
                    add(index..<end, Palette.type)
                } else {
                    plain += word
                }
                index = end
                continue
            }

            plain.append(character)
            index += 1
        }
        flushPlain()
        return result
    }

    /// Xcode's default colors, light and dark
    private enum Palette {
        static let keyword = color(light: 0x9B2393, dark: 0xFC5FA3)
        static let string = color(light: 0xC41A16, dark: 0xFC6A5D)
        static let number = color(light: 0x1C00CF, dark: 0xD0BF69)
        static let comment = color(light: 0x5D6C79, dark: 0x7F8C98)
        static let type = color(light: 0x3900A0, dark: 0xD0A8FF)

        private static func color(light: UInt32, dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { @Sendable appearance in
                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: 1
                )
            })
        }
    }
}

// MARK: - Tables

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let width: CGFloat

    var body: some View {
        let columnCount = max(table.columnCount, 1)
        let rows = [table.header] + table.rows
        ScrollView(.horizontal) {
            MarkdownTableLayout(columnCount: columnCount, availableWidth: width) {
                ForEach(0..<rows.count * columnCount, id: \.self) { index in
                    let row = index / columnCount
                    let column = index % columnCount
                    cell(rows[row].indices.contains(column) ? rows[row][column] : "", row: row, column: column)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
    }

    private func cell(_ text: String, row: Int, column: Int) -> some View {
        let isHeader = row == 0
        let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
        return Text(MarkdownStyle.inline(text, size: 12))
            .font(.system(size: 12, weight: isHeader ? .semibold : .regular))
            .lineSpacing(2)
            .multilineTextAlignment(alignment.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frame)
            .background(isHeader ? Color.primary.opacity(0.06) : row.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear)
            .overlay(alignment: .top) {
                if row > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)
                }
            }
    }
}

private extension MarkdownTable.Alignment {
    var text: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frame: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// A table's cells in columns, the table as wide as the answer: columns as
/// wide as their text when that fits (room left over shared out), else
/// narrowed in proportion, their text wrapping, down to a minimum past which
/// the table is wider than the answer and scrolls sideways.
private struct MarkdownTableLayout: Layout {
    let columnCount: Int
    let availableWidth: CGFloat

    private static let minimumColumnWidth: CGFloat = 96

    struct Cache {
        var columnWidths: [CGFloat] = []
        var rowHeights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        measure(subviews)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = measure(subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        CGSize(width: cache.columnWidths.reduce(0, +), height: cache.rowHeights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for (row, height) in cache.rowHeights.enumerated() {
            var x = bounds.minX
            for (column, width) in cache.columnWidths.enumerated() {
                let index = row * columnCount + column
                guard index < subviews.count else { return }
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: height))
                x += width
            }
            y += height
        }
    }

    private func measure(_ subviews: Subviews) -> Cache {
        guard columnCount > 0, !subviews.isEmpty else { return Cache() }
        var idealWidths = Array(repeating: CGFloat(0), count: columnCount)
        for (index, subview) in subviews.enumerated() {
            idealWidths[index % columnCount] = max(idealWidths[index % columnCount], subview.sizeThatFits(.unspecified).width.rounded(.up))
        }
        let columnWidths = Self.columnWidths(ideal: idealWidths, available: availableWidth)

        var rowHeights = Array(repeating: CGFloat(0), count: (subviews.count + columnCount - 1) / columnCount)
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidths[index % columnCount], height: nil))
            rowHeights[index / columnCount] = max(rowHeights[index / columnCount], size.height.rounded(.up))
        }
        return Cache(columnWidths: columnWidths, rowHeights: rowHeights)
    }

    private static func columnWidths(ideal: [CGFloat], available: CGFloat) -> [CGFloat] {
        let total = ideal.reduce(0, +)
        guard total > 0, available > 0 else { return ideal }
        if total <= available {
            return ideal.map { $0 + (available - total) * $0 / total }
        }
        let minimum = ideal.map { min($0, minimumColumnWidth) }
        let minimumTotal = minimum.reduce(0, +)
        guard minimumTotal < available else { return minimum }
        let room = available - minimumTotal
        let shrinkable = total - minimumTotal
        return zip(ideal, minimum).map { ideal, minimum in
            (minimum + (ideal - minimum) * room / shrinkable).rounded(.down)
        }
    }
}
