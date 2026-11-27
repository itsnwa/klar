import Foundation

/// A chat answer's Markdown, parsed into blocks as it streams in. Lines are
/// parsed once they're complete; only the block still being written is parsed
/// again as more arrives. A block's ID is its place in the answer, so its view
/// (and the text selected in it) stays as the answer grows.
nonisolated struct MarkdownDocument: Equatable, Sendable {
    /// The blocks so far, the one being written last
    private(set) var blocks: [MarkdownBlock] = []
    /// The web pages it links to, other than the one it's about, each once,
    /// in order. Known once it's finished.
    private(set) var links: [MarkdownLink] = []

    private var parser = MarkdownParser()
    /// The text after the last line break: a line still being written
    private var partialLine = ""

    mutating func append(_ text: String) {
        partialLine += text
        if let lastBreak = partialLine.lastIndex(of: "\n") {
            let complete = partialLine[..<lastBreak]
            partialLine = String(partialLine[partialLine.index(after: lastBreak)...])
            for line in complete.split(separator: "\n", omittingEmptySubsequences: false) {
                parser.add(String(line))
            }
        }

        // The block still being written, as far as it's come. Markup it hasn't
        // closed yet (`**`, a backtick, a link's address) isn't shown as
        // typed: it would flash and then turn into formatting.
        var preview = parser
        if !partialLine.isEmpty {
            preview.add(partialLine, isPartial: true)
        }
        preview.closeOpenBlock(isStreaming: true)
        var blocks = preview.closed
        for index in parser.closed.count..<blocks.count {
            blocks[index] = blocks[index].closingUnfinishedMarkup()
        }
        self.blocks = blocks
    }

    /// The whole answer is in: the last block is closed as written, and the
    /// links are collected, relative ones resolved against `base` (the page
    /// it's about).
    mutating func finish(base: URL?) {
        if !partialLine.isEmpty {
            parser.add(partialLine)
            partialLine = ""
        }
        parser.closeOpenBlock()
        blocks = parser.closed
        links = Self.links(in: blocks, base: base)
    }

    private static let maximumLinks = 12

    private static func links(in blocks: [MarkdownBlock], base: URL?) -> [MarkdownLink] {
        var links: [MarkdownLink] = []
        var seen = Set(base.map { [pageKey(of: $0)] } ?? [])
        for block in blocks {
            for text in block.inlineTexts {
                for (url, title) in MarkdownInline.links(in: text) {
                    let resolved = url.scheme == nil ? URL(string: url.relativeString, relativeTo: base)?.absoluteURL : url
                    guard let resolved, let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
                    guard seen.insert(pageKey(of: resolved)).inserted else { continue }
                    links.append(MarkdownLink(url: resolved, title: title))
                    if links.count == maximumLinks {
                        return links
                    }
                }
            }
        }
        return links
    }

    /// The page's address regardless of its fragment
    static func pageKey(of url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}

/// A block of an answer: a heading, paragraph, list item, quote, code, table
/// or divider.
nonisolated struct MarkdownBlock: Identifiable, Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(MarkdownListMarker, depth: Int, text: String)
        case quote(String)
        case code(language: String, text: String)
        case table(MarkdownTable)
        case divider
    }

    /// Its place in the answer
    let id: Int
    let kind: Kind

    /// The text in it that's Markdown of its own (not code)
    var inlineTexts: [String] {
        switch kind {
        case .heading(_, let text), .paragraph(let text), .listItem(_, _, let text), .quote(let text):
            return [text]
        case .table(let table):
            return table.header + table.rows.flatMap { $0 }
        case .code, .divider:
            return []
        }
    }

    /// While it's being written: `**`, a backtick or a link it hasn't closed
    /// yet, closed or left out for now.
    func closingUnfinishedMarkup() -> MarkdownBlock {
        let close = MarkdownInline.closingUnfinishedMarkup
        switch kind {
        case .heading(let level, let text):
            return MarkdownBlock(id: id, kind: .heading(level: level, text: close(text)))
        case .paragraph(let text):
            return MarkdownBlock(id: id, kind: .paragraph(close(text)))
        case .listItem(let marker, let depth, let text):
            return MarkdownBlock(id: id, kind: .listItem(marker, depth: depth, text: close(text)))
        case .quote(let text):
            return MarkdownBlock(id: id, kind: .quote(close(text)))
        case .table(var table):
            if var last = table.rows.popLast() {
                last = last.map(close)
                table.rows.append(last)
            } else {
                table.header = table.header.map(close)
            }
            return MarkdownBlock(id: id, kind: .table(table))
        case .code, .divider:
            return self
        }
    }
}

nonisolated enum MarkdownListMarker: Equatable, Sendable {
    case bullet
    /// As the answer numbers it
    case number(Int)
    case task(isDone: Bool)
}

nonisolated struct MarkdownTable: Equatable, Sendable {
    nonisolated enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    var header: [String]
    /// One per column
    var alignments: [Alignment]
    /// Each as many cells as the header
    var rows: [[String]]

    var columnCount: Int { header.count }
}

/// A web address an answer links to, and the text of its first link there.
nonisolated struct MarkdownLink: Identifiable, Equatable, Sendable {
    let url: URL
    let title: String

    var id: URL { url }
}

// MARK: - Blocks

/// Turns lines into blocks: GitHub's Markdown as models write it, leniently.
/// Numbered lists keep the numbers written, so no block depends on one parsed
/// before it but the open one.
private nonisolated struct MarkdownParser: Equatable, Sendable {
    private nonisolated enum OpenBlock: Equatable, Sendable {
        case paragraph([String])
        case listItem(MarkdownListMarker, depth: Int, lines: [String])
        case quote([String])
        case code(fence: String, indent: Int, language: String, lines: [String])
        case table(MarkdownTable)
    }

    private(set) var closed: [MarkdownBlock] = []
    private var open: OpenBlock?
    /// The indents of the list items above, a level each
    private var listIndents: [Int] = []

    /// One line, without its line break. A partial one is still being
    /// written: what's too short to tell (a lone `#`, `-` or `1.`) waits.
    mutating func add(_ rawLine: String, isPartial: Bool = false) {
        var line = rawLine
        if line.hasSuffix("\r") {
            line.removeLast()
        }

        // In code, every line is code until the closing fence
        if case .code(let fence, let indent, let language, var lines) = open {
            if Self.isClosingFence(line, of: fence) {
                open = nil
                emit(.code(language: language, text: lines.joined(separator: "\n")))
            } else {
                lines.append(Self.removingIndent(of: line, upTo: indent))
                open = .code(fence: fence, indent: indent, language: language, lines: lines)
            }
            return
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            closeOpenBlock()
            return
        }
        if isPartial, trimmed.count <= 3, !trimmed.contains(where: \.isLetter) {
            return
        }

        if let (fence, language) = Self.openingFence(trimmed) {
            closeOpenBlock()
            listIndents = []
            open = .code(fence: fence, indent: Self.indentWidth(of: line), language: language, lines: [])
            return
        }

        // A table's rows, until a line without a pipe
        if case .table(var table) = open {
            if trimmed.contains("|") {
                table.rows.append(Self.padded(Self.cells(of: trimmed), to: table.columnCount, with: ""))
                open = .table(table)
                return
            }
            closeOpenBlock()
        }

        // A delimiter row makes the line above it a table's header
        if trimmed.contains("|"), let alignments = Self.tableAlignments(of: trimmed),
           case .paragraph(var lines) = open, let headerLine = lines.last, headerLine.contains("|") {
            let header = Self.cells(of: headerLine)
            lines.removeLast()
            open = nil
            if !lines.isEmpty {
                emit(.paragraph(lines.joined(separator: "\n")))
            }
            listIndents = []
            open = .table(MarkdownTable(header: header, alignments: Self.padded(alignments, to: header.count, with: .leading), rows: []))
            return
        }

        if let (level, text) = Self.heading(in: trimmed) {
            closeOpenBlock()
            listIndents = []
            emit(.heading(level: level, text: text))
            return
        }

        if Self.isDivider(trimmed) {
            closeOpenBlock()
            listIndents = []
            emit(.divider)
            return
        }

        if let text = Self.quoteText(in: trimmed) {
            if case .quote(var lines) = open {
                lines.append(text)
                open = .quote(lines)
            } else {
                closeOpenBlock()
                listIndents = []
                open = .quote([text])
            }
            return
        }

        if let (marker, text) = Self.listItem(in: trimmed) {
            closeOpenBlock()
            open = .listItem(marker, depth: listDepth(forIndent: Self.indentWidth(of: line)), lines: [text])
            return
        }

        // Text: more of the paragraph, list item or quote it follows
        switch open {
        case .paragraph(var lines):
            lines.append(trimmed)
            open = .paragraph(lines)
        case .listItem(let marker, let depth, var lines):
            lines.append(trimmed)
            open = .listItem(marker, depth: depth, lines: lines)
        case .quote(var lines):
            lines.append(trimmed)
            open = .quote(lines)
        default:
            closeOpenBlock()
            listIndents = []
            open = .paragraph([trimmed])
        }
    }

    /// Ends the block being built. While streaming, rows of pipes without a
    /// delimiter row yet show as the table they're about to be.
    mutating func closeOpenBlock(isStreaming: Bool = false) {
        guard let block = open else { return }
        open = nil
        switch block {
        case .paragraph(let lines):
            if isStreaming, let first = lines.first, lines.allSatisfy({ $0.hasPrefix("|") }) {
                let header = Self.cells(of: first)
                emit(.table(MarkdownTable(header: header, alignments: Array(repeating: .leading, count: header.count), rows: [])))
            } else {
                emit(.paragraph(lines.joined(separator: "\n")))
            }
        case .listItem(let marker, let depth, let lines):
            emit(.listItem(marker, depth: depth, text: lines.joined(separator: "\n")))
        case .quote(let lines):
            emit(.quote(lines.joined(separator: "\n")))
        case .code(_, _, let language, let lines):
            emit(.code(language: language, text: lines.joined(separator: "\n")))
        case .table(let table):
            emit(.table(table))
        }
    }

    private mutating func emit(_ kind: MarkdownBlock.Kind) {
        closed.append(MarkdownBlock(id: closed.count, kind: kind))
    }

    /// An item's level: deeper than the item above when indented past it
    /// by two or more, else as deep as the item it lines up with.
    private mutating func listDepth(forIndent indent: Int) -> Int {
        while let last = listIndents.last, last > indent {
            listIndents.removeLast()
        }
        if let last = listIndents.last, indent < last + 2 {
            return listIndents.count - 1
        }
        listIndents.append(indent)
        return listIndents.count - 1
    }

    // MARK: Lines

    private static func indentWidth(of line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
    }

    private static func removingIndent(of line: String, upTo indent: Int) -> String {
        var removed = 0
        var start = line.startIndex
        while start < line.endIndex, removed < indent, line[start] == " " {
            removed += 1
            start = line.index(after: start)
        }
        return String(line[start...])
    }

    /// ``` or ~~~ (three or more), and the language after it
    private static func openingFence(_ trimmed: String) -> (fence: String, language: String)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let fence = trimmed.prefix { $0 == first }
        guard fence.count >= 3 else { return nil }
        let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
        // An inline span on one line (```code```) isn't a block
        if first == "`", info.contains("`") {
            return nil
        }
        let language = info.split(separator: " ").first.map(String.init) ?? ""
        return (String(fence), language)
    }

    private static func isClosingFence(_ line: String, of fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let character = fence.first else { return false }
        return trimmed.count >= fence.count && trimmed.allSatisfy { $0 == character }
    }

    private static func heading(in trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s isn't part of it
        if let closing = text.range(of: #"\s+#+$"#, options: .regularExpression) {
            text.removeSubrange(closing)
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return (hashes, text)
    }

    /// ---, *** or ___, spaced or not
    private static func isDivider(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func quoteText(in trimmed: String) -> String? {
        guard trimmed.hasPrefix(">") else { return nil }
        var text = trimmed.dropFirst()
        if text.first == " " {
            text = text.dropFirst()
        }
        return String(text)
    }

    private static func listItem(in trimmed: String) -> (MarkdownListMarker, String)? {
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            let text = trimmed.dropFirst(2)
            for (box, isDone) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(box) {
                return (.task(isDone: isDone), String(text.dropFirst(box.count)))
            }
            return (.bullet, String(text))
        }

        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let punctuation = rest.first, punctuation == "." || punctuation == ")",
              rest.dropFirst().first == " " else { return nil }
        return (.number(number), String(rest.dropFirst(2)))
    }

    // MARK: Tables

    /// A row's cells: split at pipes, but not escaped ones (`\|`) or ones
    /// in code.
    static func cells(of row: String) -> [String] {
        var text = Substring(row.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("|") {
            text = text.dropFirst()
        }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") {
            text = text.dropLast()
        }

        var cells: [String] = []
        var cell = ""
        var isInCode = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\\", next < text.endIndex, text[next] == "|" {
                cell.append("|")
                index = text.index(after: next)
                continue
            }
            if character == "`" {
                isInCode.toggle()
            }
            if character == "|", !isInCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            index = next
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// `| --- | :---: | ---: |`: each column's alignment, or nil for
    /// another line.
    private static func tableAlignments(of trimmed: String) -> [MarkdownTable.Alignment]? {
        var alignments: [MarkdownTable.Alignment] = []
        for cell in cells(of: trimmed) {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments.isEmpty ? nil : alignments
    }

    private static func padded<Element>(_ elements: [Element], to count: Int, with filler: Element) -> [Element] {
        if elements.count >= count {
            return Array(elements.prefix(count))
        }
        return elements + Array(repeating: filler, count: count - elements.count)
    }
}

// MARK: - Inline

/// Markdown within a block: emphasis, code, links, and web addresses written
/// out (linked too).
nonisolated enum MarkdownInline {
    static func parse(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        linkWrittenAddresses(in: &attributed)
        return attributed
    }

    /// Each link's address and text
    static func links(in text: String) -> [(URL, String)] {
        let attributed = parse(text)
        var links: [(URL, String)] = []
        for (link, range) in attributed.runs[\.link] {
            guard let link else { continue }
            let title = String(attributed[range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            links.append((link, title == link.absoluteString ? "" : title))
        }
        return links
    }

    private static let addressDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// http(s) addresses written out in text, outside code and links
    private static func linkWrittenAddresses(in attributed: inout AttributedString) {
        let plain = String(attributed.characters)
        guard plain.contains("://") || plain.contains("www."), let addressDetector else { return }
        for match in addressDetector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let range = Range(match.range, in: plain) else { continue }
            let written = plain[range]
            guard written.contains("://") || written.lowercased().hasPrefix("www.") else { continue }
            let start = attributed.characters.index(attributed.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
            let end = attributed.characters.index(start, offsetBy: written.count)
            let isPlain = attributed[start..<end].runs.allSatisfy { run in
                run.link == nil && !(run.inlinePresentationIntent?.contains(.code) ?? false)
            }
            if isPlain {
                attributed[start..<end].link = url
            }
        }
    }

    /// Text still being written, its open markup closed or left out: a link
    /// shows its text until its address is in, and `**` or a backtick is
    /// closed at the end (or dropped, if nothing follows it yet).
    static func closingUnfinishedMarkup(_ text: String) -> String {
        var text = text
        if let link = text.firstMatch(of: /\[([^\[\]]*)\]\([^)\s]*$/) {
            text.replaceSubrange(link.range, with: link.output.1)
        } else if let link = text.firstMatch(of: /\[([^\[\]]*)$/) {
            text.replaceSubrange(link.range, with: link.output.1)
        }
        if text.filter({ $0 == "`" }).count % 2 == 1 {
            if text.hasSuffix("`") {
                text.removeLast()
            } else {
                text += "`"
            }
        }
        if text.components(separatedBy: "**").count % 2 == 0 {
            if text.hasSuffix("**") {
                text.removeLast(2)
            } else {
                while text.last?.isWhitespace == true {
                    text.removeLast()
                }
                text += "**"
            }
        }
        return text
    }
}
