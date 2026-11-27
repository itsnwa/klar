import Foundation

/// Fuzzy search utility for command palette.
///
/// A candidate's text is lowercased and split into words once, when the
/// palette indexes it, and a query once per search, so scoring a candidate
/// allocates nothing. ASCII text — nearly every URL and most titles — is
/// compared byte by byte; anything else goes through the String APIs, so
/// either way the scores are exactly what matching the strings gives.
nonisolated enum FuzzySearch {

    /// A search's lowercased terms.
    struct Query {
        fileprivate let terms: [Term]

        init?(_ searchText: String) {
            let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSearch.isEmpty else { return nil }

            let terms = trimmedSearch.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .map(Term.init)
            guard !terms.isEmpty else { return nil }
            self.terms = terms
        }
    }
    
    /// A tab's or Reading List item's display title, URL and folder path,
    /// prepared for matching.
    struct Candidate {
        fileprivate let title: Field
        fileprivate let url: Field
        fileprivate let breadcrumb: Field?

        init(displayTitle: String, url: String, breadcrumb: String?) {
            self.title = Field(displayTitle.lowercased(), splitsOnPunctuation: false)
            self.url = Field(URLUtilities.cleanURL(url).lowercased(), splitsOnPunctuation: true)
            if let breadcrumb = breadcrumb, !breadcrumb.isEmpty {
                self.breadcrumb = Field(breadcrumb.lowercased(), splitsOnPunctuation: true)
            } else {
                self.breadcrumb = nil
            }
        }
    }
    
    /// The candidate's score, or nil if it doesn't match: the better of
    /// matching the terms within single fields (title weighted highest, then
    /// URL, then folder path) and matching them across fields.
    static func score(_ query: Query, _ candidate: Candidate) -> Double? {
        let termCount = query.terms.count

        // Per field: each term's best match within that field.
        var titleTotal: Double = 0
        var titleMatches = 0
        var urlTotal: Double = 0
        var urlMatches = 0
        var breadcrumbTotal: Double = 0
        var breadcrumbMatches = 0

        // Across fields: each term counts toward the field it matched best.
        var crossMatches = 0
        var crossTitle: Double = 0
        var crossURL: Double = 0
        var crossBreadcrumb: Double = 0

        for term in query.terms {
            // The title is split on whitespace either way. URLs and folder
            // paths are split on whitespace when scored on their own and
            // into their alphanumeric parts across fields.
            let title = candidate.title.bestScore(term, among: candidate.title.words)
            let urlSubstring = candidate.url.substringScore(term)
            let url = max(candidate.url.bestWordScore(term, among: candidate.url.words), urlSubstring)
            let urlParts = max(candidate.url.bestWordScore(term, among: candidate.url.parts), urlSubstring)

            if title > 0 {
                titleTotal += title
                titleMatches += 1
            }
            if url > 0 {
                urlTotal += url
                urlMatches += 1
            }

            var best = title
            var bestField = MatchedField.title
            if urlParts > best {
                best = urlParts
                bestField = .url
            }

            if let breadcrumb = candidate.breadcrumb {
                let breadcrumbSubstring = breadcrumb.substringScore(term)
                let whole = max(breadcrumb.bestWordScore(term, among: breadcrumb.words), breadcrumbSubstring)
                let parts = max(breadcrumb.bestWordScore(term, among: breadcrumb.parts), breadcrumbSubstring)
                if whole > 0 {
                    breadcrumbTotal += whole
                    breadcrumbMatches += 1
                }
                if parts > best {
                    best = parts
                    bestField = .breadcrumb
                }
            }

            if best > 0 {
                crossMatches += 1
                switch bestField {
                case .title: crossTitle += best
                case .url: crossURL += best
                case .breadcrumb: crossBreadcrumb += best
                }
            }
        }
        
        /// A field's score: the average term score, scaled by the share of
        /// terms that matched (at least 80% must).
        func fieldScore(total: Double, matches: Int) -> Double? {
            let matchRatio = Double(matches) / Double(termCount)
            guard matchRatio >= 0.8 else { return nil }
            // For single search terms, require a minimum score threshold
            if termCount == 1 && total < 0.5 { return nil }
            return (total / Double(termCount)) * matchRatio
        }

        var individualScore: Double?
        var individualTotal: Double = 0
        if let score = fieldScore(total: titleTotal, matches: titleMatches) {
            individualTotal += score * 3.0 // DisplayTitle matches are weighted highest
            individualScore = individualTotal
        }
        if let score = fieldScore(total: urlTotal, matches: urlMatches) {
            individualTotal += score * 2.0 // URL matches are weighted medium
            individualScore = individualTotal
        }
        if candidate.breadcrumb != nil, let score = fieldScore(total: breadcrumbTotal, matches: breadcrumbMatches) {
            individualTotal += score * 1.5 // Breadcrumb matches are weighted lower
            individualScore = individualTotal
        }

        var crossFieldScore: Double?
        if Double(crossMatches) / Double(termCount) >= 0.8 {
            let fieldsMatched = (crossTitle > 0 ? 1 : 0) + (crossURL > 0 ? 1 : 0) + (crossBreadcrumb > 0 ? 1 : 0)
            let weightedScore = crossTitle * 3.0 + crossURL * 2.0 + crossBreadcrumb * 1.5
            // Bonus for matching across multiple fields
            crossFieldScore = weightedScore + (fieldsMatched > 1 ? 0.2 : 0)
        }

        switch (individualScore, crossFieldScore) {
        case let (individual?, crossField?):
            return individual > crossField ? individual : crossField
        case let (individual?, nil):
            return individual
        case let (nil, crossField?):
            return crossField
        case (nil, nil):
            return nil
        }
    }

    private enum MatchedField {
        case title, url, breadcrumb
    }

    // MARK: - Prepared Text

    fileprivate struct Term {
        let text: String
        /// In Characters.
        let length: Int
        let isASCII: Bool

        init(_ term: String) {
            var text = term
            text.makeContiguousUTF8()
            self.text = text
            self.isASCII = text.utf8.allSatisfy { $0 < 0x80 }
            self.length = isASCII ? text.utf8.count : text.count
        }
    }

    fileprivate struct Field {
        let text: String
        /// In Characters, which substring positions are measured in.
        let length: Int
        /// ASCII without carriage returns, so UTF-8 offsets are Character
        /// offsets ("\r\n" is a single Character).
        let isASCII: Bool
        /// Split on whitespace.
        let words: [String]
        /// Split on everything but letters and digits; only for URLs and
        /// folder paths.
        let parts: [String]

        init(_ lowercasedText: String, splitsOnPunctuation: Bool) {
            var text = lowercasedText
            text.makeContiguousUTF8()
            let isASCII = text.utf8.allSatisfy { $0 < 0x80 && $0 != 0x0D }
            self.text = text
            self.isASCII = isASCII
            self.length = isASCII ? text.utf8.count : text.count
            self.words = FuzzySearch.split(
                text,
                isASCII: isASCII,
                isASCIISeparator: FuzzySearch.isASCIIWhitespace,
                separators: .whitespacesAndNewlines
            )
            self.parts = splitsOnPunctuation
                ? FuzzySearch.split(
                    text,
                    isASCII: isASCII,
                    isASCIISeparator: { !FuzzySearch.isASCIIAlphanumeric($0) },
                    separators: FuzzySearch.nonAlphanumerics
                )
                : []
        }

        /// The term's best score among `words` or as a substring of the text.
        func bestScore(_ term: Term, among words: [String]) -> Double {
            max(bestWordScore(term, among: words), substringScore(term))
        }

        func bestWordScore(_ term: Term, among words: [String]) -> Double {
            var best: Double = 0
            for word in words {
                let byteWise = term.isASCII && (isASCII || word.utf8.allSatisfy { $0 < 0x80 })
                let score = byteWise ? FuzzySearch.asciiWordScore(term, word) : FuzzySearch.wordScore(term, word)
                if score > best {
                    best = score
                    if best == 1.0 { break } // Nothing beats an exact match
                }
            }
            return best
        }

        /// Up to 0.6 for the term inside the text: the earlier, the higher.
        func substringScore(_ term: Term) -> Double {
            let position: Int?
            if isASCII && term.isASCII {
                position = FuzzySearch.withBytes(term.text, text) { termBytes, textBytes in
                    FuzzySearch.firstOffset(of: termBytes, in: textBytes)
                } ?? FuzzySearch.characterOffset(of: term.text, in: text)
            } else {
                position = FuzzySearch.characterOffset(of: term.text, in: text)
            }
            guard let position = position else { return 0 }
            return 0.6 * (1.0 - (Double(position) / Double(length)))
        }
    }

    private static let nonAlphanumerics = CharacterSet.alphanumerics.inverted

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    /// `components(separatedBy:)` without the empty pieces. ASCII text is
    /// split directly: there `separators` holds exactly the bytes
    /// `isASCIISeparator` accepts.
    private static func split(_ text: String, isASCII: Bool, isASCIISeparator: (UInt8) -> Bool, separators: CharacterSet) -> [String] {
        if isASCII {
            let pieces: [String]? = text.utf8.withContiguousStorageIfAvailable { bytes in
                var pieces: [String] = []
                var start = -1
                for index in 0...bytes.count {
                    if index == bytes.count || isASCIISeparator(bytes[index]) {
                        if start == 0 && index == bytes.count {
                            pieces.append(text) // No separators: share the text's storage
                        } else if start >= 0 {
                            pieces.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self))
                        }
                        start = -1
                    } else if start < 0 {
                        start = index
                    }
                }
                return pieces
            }
            if let pieces = pieces {
                return pieces
            }
        }
        
        return text.components(separatedBy: separators).compactMap { piece -> String? in
            guard !piece.isEmpty else { return nil }
            var word = piece
            word.makeContiguousUTF8()
            return word
        }
    }

    // MARK: - Word Scoring

    /// How well `term` matches `word`: exactly (1.0), as its prefix (0.9),
    /// inside it (0.7), or — for terms of four or more characters — within a
    /// small edit distance (below 0.3).
    ///
    /// An abbreviation check used to run before the edit distance; its score
    /// topped out at exactly its 0.5 threshold, so it never matched.
    private static func wordScore(_ term: Term, _ word: String) -> Double {
        if word == term.text { return 1.0 }
        if word.hasPrefix(term.text) { return 0.9 }
        if word.contains(term.text) { return 0.7 }

        guard term.length >= 4 else { return 0 }
        let wordLength = word.count
        guard term.length <= wordLength,
              wordLength <= term.length * 2,
              canBeSimilar(termLength: term.length, wordLength: wordLength) else { return 0 }

        let distance = Array(term.text).withUnsafeBufferPointer { termCharacters in
            Array(word).withUnsafeBufferPointer { wordCharacters in
                levenshteinDistance(termCharacters, wordCharacters)
            }
        }
        let similarity = 1.0 - (Double(distance) / Double(wordLength))
        return similarity > 0.8 ? similarity * 0.3 : 0
    }

    /// `wordScore` on bytes, for ASCII terms and words (where bytes are
    /// Characters).
    private static func asciiWordScore(_ term: Term, _ word: String) -> Double {
        let score = withBytes(term.text, word) { termBytes, wordBytes -> Double in
            let termLength = termBytes.count
            let wordLength = wordBytes.count

            if wordLength >= termLength && hasPrefix(wordBytes, termBytes) {
                return wordLength == termLength ? 1.0 : 0.9
            }
            if wordLength > termLength && firstOffset(of: termBytes, in: wordBytes) != nil {
                return 0.7
            }

            guard termLength >= 4,
                  termLength <= wordLength,
                  wordLength <= termLength * 2,
                  canBeSimilar(termLength: termLength, wordLength: wordLength) else { return 0 }
            let similarity = 1.0 - (Double(levenshteinDistance(termBytes, wordBytes)) / Double(wordLength))
            return similarity > 0.8 ? similarity * 0.3 : 0
        }
        return score ?? wordScore(term, word)
    }

    /// The edit distance is at least the length difference, so when that
    /// alone keeps the similarity from exceeding 0.8 the distance needn't be
    /// computed.
    private static func canBeSimilar(termLength: Int, wordLength: Int) -> Bool {
        1.0 - (Double(wordLength - termLength) / Double(wordLength)) > 0.8
    }

    // MARK: - Primitives

    /// Calls `body` with both strings' UTF-8 bytes; nil if either isn't
    /// stored contiguously.
    private static func withBytes<Value>(
        _ first: String,
        _ second: String,
        _ body: (UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>) -> Value
    ) -> Value? {
        let result: Value?? = first.utf8.withContiguousStorageIfAvailable { firstBytes in
            second.utf8.withContiguousStorageIfAvailable { secondBytes in
                body(firstBytes, secondBytes)
            }
        }
        return result ?? nil
    }

    private static func hasPrefix(_ bytes: UnsafeBufferPointer<UInt8>, _ prefix: UnsafeBufferPointer<UInt8>) -> Bool {
        guard prefix.count <= bytes.count else { return false }
        for index in 0..<prefix.count where bytes[index] != prefix[index] {
            return false
        }
        return true
    }

    private static func firstOffset(of needle: UnsafeBufferPointer<UInt8>, in haystack: UnsafeBufferPointer<UInt8>) -> Int? {
        let needleCount = needle.count
        guard needleCount > 0 else { return 0 }
        guard needleCount <= haystack.count else { return nil }

        let first = needle[0]
        for start in 0...(haystack.count - needleCount) where haystack[start] == first {
            var matched = 1
            while matched < needleCount && haystack[start + matched] == needle[matched] {
                matched += 1
            }
            if matched == needleCount {
                return start
            }
        }
        return nil
    }

    /// Where `term` first occurs in `text`, in Characters.
    private static func characterOffset(of term: String, in text: String) -> Int? {
        guard text.contains(term), let range = text.range(of: term) else { return nil }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    /// Calculate Levenshtein distance, keeping two rows of the matrix on the stack.
    private static func levenshteinDistance<Element: Equatable>(_ first: UnsafeBufferPointer<Element>, _ second: UnsafeBufferPointer<Element>) -> Int {
        let firstCount = first.count
        let secondCount = second.count
        if firstCount == 0 { return secondCount }
        if secondCount == 0 { return firstCount }

        return withUnsafeTemporaryAllocation(of: Int.self, capacity: (secondCount + 1) * 2) { buffer in
            var previous = UnsafeMutableBufferPointer(rebasing: buffer[0...secondCount])
            var current = UnsafeMutableBufferPointer(rebasing: buffer[(secondCount + 1)...])
            for column in 0...secondCount {
                previous[column] = column
            }
            for row in 1...firstCount {
                current[0] = row
                for column in 1...secondCount {
                    let cost = first[row - 1] == second[column - 1] ? 0 : 1
                    current[column] = min(
                        previous[column] + 1,       // deletion
                        current[column - 1] + 1,    // insertion
                        previous[column - 1] + cost // substitution
                    )
                }
                swap(&previous, &current)
            }
            return previous[secondCount]
        }
    }
} 
