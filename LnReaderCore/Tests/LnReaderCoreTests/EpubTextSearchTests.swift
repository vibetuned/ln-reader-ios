import XCTest
@testable import LnReaderCore

/// Port of the Android EpubTextSearchTest — same cases, same expectations.
final class EpubTextSearchTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func page(_ name: String, _ body: String) throws -> String {
        let html = "<html><head><title>ignore me</title></head><body>\(body)</body></html>"
        try html.write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return name
    }

    func testFindsMatchAcrossInlineTags() throws {
        // "word" split by an inline tag must still match, with no phantom separator.
        let paths = [try page("a.xhtml", "<p>a wo<i>rd</i> here</p>")]
        let results = EpubTextSearch.search(rootDir: tempDir, spinePaths: paths, query: "word")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].spineIndex, 0)
        XCTAssertEqual(results[0].occurrence, 0)
    }

    func testCountsOccurrencesPerPageInDocumentOrder() throws {
        let paths = [
            try page("a.xhtml", "<p>Fox one.</p><p>fox two.</p>"),
            try page("b.xhtml", "<p>FOX three.</p>"),
        ]
        let results = EpubTextSearch.search(rootDir: tempDir, spinePaths: paths, query: "fox")
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map { [$0.spineIndex, $0.occurrence] }, [[0, 0], [0, 1], [1, 0]])
    }

    func testMatchesFlexibleWhitespaceAndNbsp() throws {
        let paths = [try page("a.xhtml", "<p>hello\n   there</p><p>hello&nbsp;there</p>")]
        let results = EpubTextSearch.search(rootDir: tempDir, spinePaths: paths, query: "hello there")
        XCTAssertEqual(results.count, 2)
    }

    func testDecodesEntitiesInMatchesAndSnippets() throws {
        let paths = [try page("a.xhtml", "<p>Tom &amp; Jerry &#65;gain</p>")]
        XCTAssertEqual(
            EpubTextSearch.search(rootDir: tempDir, spinePaths: paths, query: "Tom & Jerry").count, 1)
        XCTAssertEqual(
            EpubTextSearch.search(rootDir: tempDir, spinePaths: paths, query: "Again").count, 1)
    }

    func testIgnoresHeadScriptStyleAndComments() throws {
        let html = "<html><head><title>needle</title></head><body>"
            + "<script>var needle=1;</script><style>.needle{}</style>"
            + "<!-- needle --><p>hay</p></body></html>"
        try html.write(to: tempDir.appendingPathComponent("a.xhtml"), atomically: true, encoding: .utf8)
        XCTAssertTrue(
            EpubTextSearch.search(rootDir: tempDir, spinePaths: ["a.xhtml"], query: "needle").isEmpty)
    }

    func testSnippetMarksTheMatchedRange() throws {
        let paths = [try page("a.xhtml", "<p>The quick brown fox jumps over the lazy dog.</p>")]
        let results = EpubTextSearch.search(rootDir: tempDir, spinePaths: paths, query: "brown FOX")
        XCTAssertEqual(results.count, 1)
        let result = results[0]
        let start = result.snippet.index(result.snippet.startIndex, offsetBy: result.matchStart)
        let end = result.snippet.index(start, offsetBy: result.matchLength)
        XCTAssertEqual(String(result.snippet[start ..< end]), "brown fox")
    }

    func testJsPatternEscapesRegexSpecialsAndJoinsWordsFlexibly() {
        XCTAssertEqual(EpubTextSearch.jsPattern(for: "a.b*c"), #"a\.b\*c"#)
        XCTAssertEqual(EpubTextSearch.jsPattern(for: "  one   two "), #"one[\s\u00A0]+two"#)
        XCTAssertNil(EpubTextSearch.jsPattern(for: "   "))
    }

    func testCapsResultCount() throws {
        let body = Array(repeating: "again", count: EpubTextSearch.maxResults + 50).joined(separator: " ")
        let paths = [try page("a.xhtml", "<p>\(body)</p>")]
        XCTAssertEqual(
            EpubTextSearch.search(rootDir: tempDir, spinePaths: paths, query: "again").count,
            EpubTextSearch.maxResults)
    }
}
