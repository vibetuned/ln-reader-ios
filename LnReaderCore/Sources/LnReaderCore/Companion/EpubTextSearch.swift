import Foundation

/// One search hit: the k-th occurrence of the query on a spine page, with a display snippet.
public struct EpubSearchMatch: Equatable, Sendable {
    public let spineIndex: Int
    /// 0-based index of this match among the matches on its page, in document order.
    public let occurrence: Int
    public let snippet: String
    /// Character range of the matched text inside `snippet`, for emphasis in the results list.
    public let matchStart: Int
    public let matchLength: Int
}

/// Whole-book plain-text search over an extracted EPUB — a 1:1 port of the
/// Android EpubTextSearch.
///
/// The reader highlights hits by walking the WebView's DOM text nodes in JS and
/// wrapping the k-th regex match. For `occurrence` to point at the right
/// highlight, both sides must see the same text in the same order, so
/// `extractText` mirrors what the DOM walk concatenates: markup contributes
/// nothing (no implied separator), entities are decoded, and head/script/style
/// content is dropped. Queries match with flexible whitespace (any run of
/// whitespace or NBSP in the document matches a single space in the query) on
/// both sides.
public enum EpubTextSearch {
    /// Hard cap so a one-letter query on a long book can't build an unbounded result list.
    public static let maxResults = 500

    private static let snippetContextChars = 60
    /// Named explicitly on both sides: Foundation's \s matches NBSP but JS's does too —
    /// keeping the run spelled out guarantees the two patterns agree.
    private static let whitespaceRun = "[\\s\\u00A0]+"

    public static func search(rootDir: URL, spinePaths: [String], query: String) -> [EpubSearchMatch] {
        guard let pattern = nativePattern(for: query) else { return [] }
        var results: [EpubSearchMatch] = []
        for (spineIndex, path) in spinePaths.enumerated() {
            guard let html = try? String(contentsOf: rootDir.appendingPathComponent(path), encoding: .utf8)
            else { continue }
            let text = extractText(html)
            let nsText = text as NSString
            var occurrence = 0
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                results.append(snippet(for: match.range, in: nsText, spineIndex: spineIndex, occurrence: occurrence))
                occurrence += 1
                if results.count >= maxResults { return results }
            }
        }
        return results
    }

    private static func nativePattern(for query: String) -> NSRegularExpression? {
        guard let words = splitQuery(query) else { return nil }
        let source = words
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: whitespaceRun)
        return try? NSRegularExpression(pattern: source, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    /// The same pattern but escaped for JS `new RegExp(...)`. Nil for a blank query.
    public static func jsPattern(for query: String) -> String? {
        guard let words = splitQuery(query) else { return nil }
        return words
            .map { word in
                var escaped = ""
                for character in word {
                    if "\\.*+?^${}()|[]".contains(character) {
                        escaped.append("\\")
                    }
                    escaped.append(character)
                }
                return escaped
            }
            .joined(separator: whitespaceRun)
    }

    private static func splitQuery(_ query: String) -> [String]? {
        var separators = CharacterSet.whitespacesAndNewlines
        separators.insert("\u{00A0}")
        let words = query.components(separatedBy: separators).filter { !$0.isEmpty }
        return words.isEmpty ? nil : words
    }

    // MARK: - Text extraction (mirrors the JS DOM text-node walk)

    private static let headBlock = regex("<head[^>]*>.*?</head>")
    private static let scriptStyleBlock = regex("<(script|style)[^>]*>.*?</\\1>")
    private static let comment = regex("<!--.*?-->")
    private static let tag = regex("<[^>]+>")

    static func extractText(_ html: String) -> String {
        var text = html
        for stripper in [headBlock, scriptStyleBlock, comment, tag] {
            text = stripper.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: "")
        }
        return decodeEntities(text)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let entity = regex("&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);")

    /// The named entities that actually show up in EPUB prose. An unknown
    /// entity is left verbatim — both sides simply won't match inside it.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "shy": "\u{00AD}",
        "mdash": "—", "ndash": "–", "hellip": "…",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
    ]

    private static func decodeEntities(_ input: String) -> String {
        let ns = input as NSString
        var output = ""
        var cursor = 0
        for match in entity.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let body = ns.substring(with: match.range(at: 1))
            let decoded: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(scalarString)
            } else if body.hasPrefix("#") {
                decoded = UInt32(body.dropFirst(1)).flatMap(scalarString)
            } else {
                decoded = namedEntities[body]
            }
            output += decoded ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    private static func scalarString(_ value: UInt32) -> String? {
        Unicode.Scalar(value).map { String(Character($0)) }
    }

    // MARK: - Snippets

    private static let whitespace = regex("[\\s\\u00A0]+")

    private static func snippet(
        for matchRange: NSRange, in text: NSString, spineIndex: Int, occurrence: Int
    ) -> EpubSearchMatch {
        let start = matchRange.location
        let end = matchRange.location + matchRange.length
        let preStart = max(0, start - snippetContextChars)
        let postEnd = min(text.length, end + snippetContextChars)
        let preRaw = text.substring(with: NSRange(location: preStart, length: start - preStart))
        let postRaw = text.substring(with: NSRange(location: end, length: postEnd - end))
        let prefix = start > snippetContextChars ? "…" : ""
        let suffix = end + snippetContextChars < text.length ? "…" : ""

        let pre = prefix + collapseWhitespace(preRaw).trimmedStart()
        let matched = collapseWhitespace(text.substring(with: matchRange))
        let post = collapseWhitespace(postRaw).trimmedEnd() + suffix
        return EpubSearchMatch(
            spineIndex: spineIndex,
            occurrence: occurrence,
            snippet: pre + matched + post,
            matchStart: pre.count,
            matchLength: matched.count
        )
    }

    private static func collapseWhitespace(_ input: String) -> String {
        whitespace.stringByReplacingMatches(
            in: input, range: NSRange(location: 0, length: (input as NSString).length),
            withTemplate: " ")
    }
}

private extension String {
    func trimmedStart() -> String {
        String(drop(while: { $0.isWhitespace }))
    }

    func trimmedEnd() -> String {
        String(reversed().drop(while: { $0.isWhitespace }).reversed())
    }
}
