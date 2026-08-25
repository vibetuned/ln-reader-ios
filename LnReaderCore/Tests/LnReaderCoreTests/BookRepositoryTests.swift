import XCTest
@testable import LnReaderCore

final class BookRepositoryTests: XCTestCase {
    private var tempDir: URL!
    private var fileStore: FileStore!
    private var repository: BookRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lnreader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = FileStore(baseURL: tempDir)
        repository = BookRepository(database: try AppDatabase.inMemory(), fileStore: fileStore)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeSampleM4b(named name: String = "sample.m4b") throws -> URL {
        let ilst = AtomBuilder.atom(
            "ilst",
            AtomBuilder.stringItem("\u{A9}nam", "Sample Book")
                + AtomBuilder.stringItem("\u{A9}ART", "Sample Author")
                + AtomBuilder.atom("covr", AtomBuilder.dataAtom(typeIndicator: 13, value: AtomBuilder.jpegBytes)
                    + AtomBuilder.dataAtom(typeIndicator: 14, value: AtomBuilder.pngBytes))
        )
        let udta = AtomBuilder.atom(
            "udta",
            AtomBuilder.meta(ilst) + AtomBuilder.chpl(chapters: [
                (ticks: 0, title: "One"),
                (ticks: 60 * 10_000_000, title: "Two"),
            ])
        )
        let moov = AtomBuilder.atom("moov", AtomBuilder.mvhdV0(timescale: 600, duration: 90_000) + udta)
        let bytes = AtomBuilder.atom("ftyp", AtomBuilder.fourCC("M4B ")) + moov
        let url = tempDir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func testImportCopiesParsesAndInserts() async throws {
        let source = try writeSampleM4b()
        let book = try await repository.importBook(from: source)

        XCTAssertEqual(book.title, "Sample Book")
        XCTAssertEqual(book.author, "Sample Author")
        XCTAssertEqual(book.durationMs, 150_000)
        XCTAssertEqual(book.coverPath, "books/\(book.id)/images/0.jpg")

        // Audio was copied into the store, original untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileStore.url(for: book.audioPath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let detail = try await repository.detail(bookId: book.id)
        XCTAssertEqual(detail?.chapters.map(\.title), ["One", "Two"])
        XCTAssertEqual(detail?.chapters.map(\.startMs), [0, 60_000])
        XCTAssertEqual(detail?.images.count, 2)
        let imageURL = fileStore.url(for: detail!.images[1].cachePath)
        XCTAssertEqual(try Data(contentsOf: imageURL), AtomBuilder.pngBytes)
    }

    func testImportProgressPhases() async throws {
        let source = try writeSampleM4b()
        let phases = Phases()
        _ = try await repository.importBook(from: source) { phase in
            phases.append(phase)
        }
        let seen = phases.snapshot()
        guard case .copying = seen.first else {
            return XCTFail("expected first phase to be copying, got \(String(describing: seen.first))")
        }
        XCTAssertTrue(seen.contains(.parsing))
        XCTAssertEqual(seen.last, .finalizing)
    }

    func testImportFailureCleansUpFiles() async throws {
        let source = tempDir.appendingPathComponent("broken.m4b")
        try Data("not an mp4 at all".utf8).write(to: source)

        do {
            _ = try await repository.importBook(from: source)
            XCTFail("expected import to throw")
        } catch {}

        // No books/<id> dir may survive a failed import.
        let booksDir = tempDir.appendingPathComponent("books")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: booksDir.path)) ?? []
        XCTAssertEqual(leftovers, [])

        var iterator = repository.observeBooks().makeAsyncIterator()
        let items = try await iterator.next()
        XCTAssertEqual(items, [])
    }

    func testDeleteRemovesRowCascadesAndFiles() async throws {
        let source = try writeSampleM4b()
        let book = try await repository.importBook(from: source)
        let bookDir = fileStore.bookDir(bookId: book.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookDir.path))

        try await repository.delete(bookId: book.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: bookDir.path))
        let detail = try await repository.detail(bookId: book.id)
        XCTAssertNil(detail)
    }

    func testObserveBooksJoinsPositions() async throws {
        let source = try writeSampleM4b()
        let book = try await repository.importBook(from: source)

        var iterator = repository.observeBooks().makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.map(\.id), [book.id])
        XCTAssertNil(initial?.first?.progress)
    }

    func testAttachAndDetachCompanions() async throws {
        let source = try writeSampleM4b()
        let book = try await repository.importBook(from: source)

        let epub = tempDir.appendingPathComponent("companion.epub")
        try Data("epub-bytes".utf8).write(to: epub)
        try await repository.attachEpub(bookId: book.id, from: epub)

        var detail = try await repository.detail(bookId: book.id)
        XCTAssertEqual(detail?.book.epubPath, "companions/\(book.id)/book.epub")

        try await repository.detachEpub(bookId: book.id)
        detail = try await repository.detail(bookId: book.id)
        XCTAssertNil(detail?.book.epubPath)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fileStore.companionsDir(bookId: book.id).appendingPathComponent("book.epub").path))
    }
}

/// Thread-safe phase collector (progress callbacks are @Sendable).
private final class Phases: @unchecked Sendable {
    private var phases: [ImportPhase] = []
    private let lock = NSLock()

    func append(_ phase: ImportPhase) {
        lock.lock()
        defer { lock.unlock() }
        phases.append(phase)
    }

    func snapshot() -> [ImportPhase] {
        lock.lock()
        defer { lock.unlock() }
        return phases
    }
}
