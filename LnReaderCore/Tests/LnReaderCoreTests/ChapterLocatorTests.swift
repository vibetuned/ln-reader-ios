import XCTest
@testable import LnReaderCore

final class ChapterLocatorTests: XCTestCase {
    private func chapter(_ index: Int, _ title: String, _ startMs: Int64) -> Chapter {
        Chapter(id: nil, bookId: "b", orderIndex: index, title: title, startMs: startMs)
    }

    private var locator: ChapterLocator {
        ChapterLocator(
            chapters: [
                chapter(0, "One", 0),
                chapter(1, "Two", 60_000),
                chapter(2, "Three", 150_000),
            ],
            bookDurationMs: 200_000
        )
    }

    func testWindowAtPosition() {
        XCTAssertEqual(locator.window(atMs: 0)?.title, "One")
        XCTAssertEqual(locator.window(atMs: 59_999)?.title, "One")
        XCTAssertEqual(locator.window(atMs: 60_000)?.title, "Two")
        XCTAssertEqual(locator.window(atMs: 999_999)?.title, "Three")
        // Positions before the first chapter clamp to it.
        XCTAssertEqual(locator.window(atMs: -5)?.title, "One")
    }

    func testWindowBounds() {
        let middle = locator.window(atMs: 100_000)
        XCTAssertEqual(middle?.startMs, 60_000)
        XCTAssertEqual(middle?.endMs, 150_000)
        XCTAssertEqual(middle?.durationMs, 90_000)
        // Last chapter ends at book duration.
        XCTAssertEqual(locator.window(atMs: 180_000)?.endMs, 200_000)
    }

    func testWindowAtIndex() {
        XCTAssertEqual(locator.window(atIndex: 1)?.title, "Two")
        XCTAssertNil(locator.window(atIndex: 3))
        XCTAssertNil(locator.window(atIndex: -1))
    }

    func testNoChapters() {
        let empty = ChapterLocator(chapters: [], bookDurationMs: 100)
        XCTAssertNil(empty.window(atMs: 0))
    }
}

final class PositionRepositoryTests: XCTestCase {
    func testSaveGetLastPlayed() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lnreader-pos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let database = try AppDatabase.inMemory()
        let repository = BookRepository(database: database, fileStore: FileStore(baseURL: tempDir))
        let positions = PositionRepository(database: database)

        // Two minimal books straight into the db.
        let makeBook = { (id: String) in
            Book(id: id, title: id, author: nil, album: nil, durationMs: 1000, audioPath: "x",
                 coverPath: nil, fileSize: 0, importedAt: Date(), epubPath: nil, syncPath: nil, collectionId: nil)
        }
        try await database.writer.write { db in
            try makeBook("a").insert(db)
            try makeBook("b").insert(db)
        }

        // Sleeps keep updatedAt ordering unambiguous (stored with ms precision).
        try await positions.save(bookId: "a", positionMs: 111)
        try await Task.sleep(nanoseconds: 5_000_000)
        try await positions.save(bookId: "b", positionMs: 222)
        try await Task.sleep(nanoseconds: 5_000_000)
        try await positions.save(bookId: "a", positionMs: 333) // a becomes most recent

        let a = try await positions.get(bookId: "a")
        XCTAssertEqual(a, 333)
        let last = try await positions.lastPlayedBookId()
        XCTAssertEqual(last, "a")

        // Saving for a non-existent book is a no-op, not an FK crash.
        try await positions.save(bookId: "ghost", positionMs: 1)
        let ghost = try await positions.get(bookId: "ghost")
        XCTAssertNil(ghost)

        try await positions.clear(bookId: "a")
        let cleared = try await positions.get(bookId: "a")
        XCTAssertNil(cleared)
        let lastAfterClear = try await positions.lastPlayedBookId()
        XCTAssertEqual(lastAfterClear, "b")

        _ = repository // silence unused (repository exercises FileStore wiring)
    }
}
