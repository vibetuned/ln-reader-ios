import XCTest
@testable import LnReaderCore

/// EPUB-only books, the reader's saved place, and the usage log — the v2 schema.
final class EpubOnlyAndUsageLogTests: XCTestCase {
    private var tempDir: URL!
    private var fileStore: FileStore!
    private var database: AppDatabase!
    private var books: BookRepository!
    private var positions: PositionRepository!
    private var readingPositions: ReadingPositionRepository!
    private var readLog: ReadLogRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lnreader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = FileStore(baseURL: tempDir)
        database = try AppDatabase.inMemory()
        books = BookRepository(database: database, fileStore: fileStore)
        positions = PositionRepository(database: database)
        readingPositions = ReadingPositionRepository(database: database)
        readLog = ReadLogRepository(database: database)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // A minimal EPUB 3 with Dublin Core metadata and a manifest-flagged cover image.
    private func writeEpub(named name: String = "novel.epub", withCover: Bool = true) throws -> URL {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let coverItem = withCover
            ? #"<item id="cover-img" href="Images/cover.png" media-type="image/png" properties="cover-image"/>"#
            : ""
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
          <metadata>
            <dc:title>A Quiet Volume</dc:title>
            <dc:creator>Someone Careful</dc:creator>
            <dc:creator>Second Author</dc:creator>
          </metadata>
          <manifest>
            \(coverItem)
            <item id="ch1" href="Text/one.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="Text/two.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="ch1"/><itemref idref="ch2"/></spine>
        </package>
        """
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
        var entries: [ZipBuilder.Entry] = [
            .init(name: "mimetype", content: Data("application/epub+zip".utf8), deflated: false),
            .init(name: "META-INF/container.xml", content: Data(container.utf8), deflated: true),
            .init(name: "OEBPS/content.opf", content: Data(opf.utf8), deflated: true),
            .init(name: "OEBPS/Text/one.xhtml",
                  content: Data("<html><head><title>1</title></head><body>one</body></html>".utf8), deflated: true),
            .init(name: "OEBPS/Text/two.xhtml",
                  content: Data("<html><head><title>2</title></head><body>two</body></html>".utf8), deflated: true),
        ]
        if withCover {
            entries.append(.init(name: "OEBPS/Images/cover.png", content: png, deflated: false))
        }
        let url = tempDir.appendingPathComponent(name)
        try ZipBuilder.build(entries).write(to: url)
        return url
    }

    // MARK: - EPUB-only import

    func testImportBookRoutesEpubToEpubOnlyImport() async throws {
        let source = try writeEpub()
        let book = try await books.importBook(from: source)

        XCTAssertEqual(book.mediaKind, MediaKind.epub)
        XCTAssertFalse(book.hasAudio)
        XCTAssertEqual(book.title, "A Quiet Volume")
        XCTAssertEqual(book.author, "Someone Careful", "first dc:creator wins")
        XCTAssertEqual(book.durationMs, 0)
        XCTAssertEqual(book.audioPath, "")
        // Page count is taken at import so the library tile can read "1 / 2" before the book is
        // ever opened; the fixture's spine has two documents.
        XCTAssertEqual(book.spineCount, 2)
        XCTAssertEqual(book.epubPath, "companions/\(book.id)/book.epub")
        XCTAssertEqual(book.coverPath, "books/\(book.id)/images/0.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileStore.url(for: book.epubPath!).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileStore.url(for: book.coverPath!).path))
        // Extracted where the reader expects it, so opening it is instant.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fileStore.epubExtractionDir(bookId: book.id).appendingPathComponent("OEBPS/Text/one.xhtml").path))
        // Original untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testEpubWithoutCoverOrTitleFallsBackToFileName() async throws {
        let url = tempDir.appendingPathComponent("untitled.epub")
        let container = """
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <manifest><item id="p" href="p.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="p"/></spine>
        </package>
        """
        try ZipBuilder.build([
            .init(name: "META-INF/container.xml", content: Data(container.utf8), deflated: true),
            .init(name: "content.opf", content: Data(opf.utf8), deflated: true),
            .init(name: "p.xhtml", content: Data("<html><body>p</body></html>".utf8), deflated: true),
        ]).write(to: url)

        let book = try await books.importBook(from: url)
        XCTAssertEqual(book.title, "untitled")
        XCTAssertEqual(book.spineCount, 1)
        XCTAssertNil(book.author)
        XCTAssertNil(book.coverPath)
    }

    func testEpub2MetaCoverIsResolvedThroughManifest() throws {
        let dir = tempDir.appendingPathComponent("epub2")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("OPS/img"), withIntermediateDirectories: true)
        try """
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: dir.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try """
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
          <metadata><dc:title> Spaced Title </dc:title><meta name="cover" content="cov"/></metadata>
          <manifest>
            <item id="cov" href="img/front%20cover.jpg" media-type="image/jpeg"/>
            <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="a"/></spine>
        </package>
        """.write(to: dir.appendingPathComponent("OPS/book.opf"), atomically: true, encoding: .utf8)

        let parsed = try EpubReader.parse(extractedDir: dir)
        XCTAssertEqual(parsed.title, "Spaced Title")
        XCTAssertEqual(parsed.coverPath, "OPS/img/front cover.jpg")
        XCTAssertEqual(parsed.spine, ["OPS/a.xhtml"])
    }

    func testDeletingEpubOnlyBookRemovesFilesAndReadingPosition() async throws {
        let book = try await books.importBook(from: try writeEpub())
        try await readingPositions.save(bookId: book.id, spineIndex: 1, scrollFraction: 0.5, spineCount: 2)
        let beforeDelete = try await readingPositions.get(bookId: book.id)
        XCTAssertNotNil(beforeDelete)

        try await books.delete(bookId: book.id)

        let afterDelete = try await readingPositions.get(bookId: book.id)
        XCTAssertNil(afterDelete, "cascades with the book")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileStore.companionsDir(bookId: book.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileStore.epubExtractionDir(bookId: book.id).path))
    }

    // MARK: - Reading position

    func testReadingPositionRoundTripAndProgress() async throws {
        let book = try await books.importBook(from: try writeEpub())
        try await readingPositions.save(bookId: book.id, spineIndex: 1, scrollFraction: 0.5, spineCount: 2)

        let savedRow = try await readingPositions.get(bookId: book.id)
        let saved = try XCTUnwrap(savedRow)
        XCTAssertEqual(saved.spineIndex, 1)
        XCTAssertEqual(saved.scrollFraction, 0.5)
        XCTAssertEqual(saved.fraction, 0.75, accuracy: 0.0001, "(1 + 0.5) / 2")

        // Out-of-range values are clamped rather than stored.
        try await readingPositions.save(bookId: book.id, spineIndex: -3, scrollFraction: 1.7, spineCount: 2)
        let clampedRow = try await readingPositions.get(bookId: book.id)
        let clamped = try XCTUnwrap(clampedRow)
        XCTAssertEqual(clamped.spineIndex, 0)
        XCTAssertEqual(clamped.scrollFraction, 1.0)

        // The library list carries it as the book's progress, since there is no audio to measure by.
        var iterator = books.observeBooks().makeAsyncIterator()
        let items = try await iterator.next()
        let item = try XCTUnwrap(items?.first { $0.id == book.id })
        XCTAssertEqual(item.progress ?? -1, 0.5, accuracy: 0.0001, "(0 + 1.0) / 2 after clamping")
    }

    func testReadingPositionIgnoresUnknownBook() async throws {
        try await readingPositions.save(bookId: "ghost", spineIndex: 0, scrollFraction: 0, spineCount: 1)
        let ghost = try await readingPositions.get(bookId: "ghost")
        XCTAssertNil(ghost)
    }

    func testLastActivityPicksNewerOfListenAndRead() async throws {
        let audio = try await books.importBook(from: try writeSampleM4b())
        let epub = try await books.importBook(from: try writeEpub())

        try await positions.save(bookId: audio.id, positionMs: 1_000)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await readingPositions.save(bookId: epub.id, spineIndex: 0, scrollFraction: 0.2, spineCount: 2)

        let lastPlayedRow = try await positions.lastPlayed()
        let lastReadRow = try await readingPositions.lastRead()
        let lastPlayed = try XCTUnwrap(lastPlayedRow)
        let lastRead = try XCTUnwrap(lastReadRow)
        XCTAssertEqual(lastPlayed.bookId, audio.id)
        XCTAssertEqual(lastRead.bookId, epub.id)
        XCTAssertGreaterThan(lastRead.updatedAt, lastPlayed.updatedAt, "the read came later, so it resumes into the reader")
    }

    // MARK: - Usage log

    func testReadLogSessionLifecycle() async throws {
        let book = try await books.importBook(from: try writeEpub())
        let id = try await readLog.start(bookId: book.id, bookTitle: book.title, kind: .read, position: 0)

        var rows = try await readLog.forBook(book.id)
        var entry = try XCTUnwrap(rows.first)
        XCTAssertEqual(entry.kind, .read)
        XCTAssertEqual(entry.startedAt, entry.endedAt, "opens as a zero-length session")

        try await Task.sleep(nanoseconds: 20_000_000)
        try await readLog.heartbeat(sessionId: id, position: 1)
        rows = try await readLog.forBook(book.id)
        entry = try XCTUnwrap(rows.first)
        XCTAssertGreaterThan(entry.endedAt, entry.startedAt)
        XCTAssertEqual(entry.endPosition, 1)

        try await readLog.end(sessionId: id, position: 2)
        rows = try await readLog.forBook(book.id)
        entry = try XCTUnwrap(rows.first)
        XCTAssertEqual(entry.endPosition, 2)
        XCTAssertGreaterThan(entry.duration, 0)
    }

    func testReadLogSurvivesBookDeletionAndFiltersByDate() async throws {
        let book = try await books.importBook(from: try writeEpub())
        let id = try await readLog.start(bookId: book.id, bookTitle: book.title, kind: .listen, position: 5_000)
        try await readLog.end(sessionId: id, position: 65_000)

        try await books.delete(bookId: book.id)

        let all = try await readLog.all()
        XCTAssertEqual(all.count, 1, "usage history outlives the book")
        XCTAssertEqual(all[0].bookTitle, "A Quiet Volume", "title snapshot survives the deletion")

        let today = try await readLog.between(Date().addingTimeInterval(-60), Date().addingTimeInterval(60))
        XCTAssertEqual(today.count, 1)
        let yesterday = try await readLog.between(Date().addingTimeInterval(-7_200), Date().addingTimeInterval(-3_600))
        XCTAssertTrue(yesterday.isEmpty)
    }

    // MARK: - Fixture

    private func writeSampleM4b() throws -> URL {
        let ilst = AtomBuilder.atom("ilst", AtomBuilder.stringItem("\u{A9}nam", "Sample Book"))
        let udta = AtomBuilder.atom("udta", AtomBuilder.meta(ilst))
        let moov = AtomBuilder.atom("moov", AtomBuilder.mvhdV0(timescale: 600, duration: 90_000) + udta)
        let bytes = AtomBuilder.atom("ftyp", AtomBuilder.fourCC("M4B ")) + moov
        let url = tempDir.appendingPathComponent("sample.m4b")
        try bytes.write(to: url)
        return url
    }
}
