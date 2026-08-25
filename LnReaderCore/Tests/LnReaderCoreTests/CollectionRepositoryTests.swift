import XCTest
@testable import LnReaderCore

final class CollectionRepositoryTests: XCTestCase {
    private var database: AppDatabase!
    private var collections: CollectionRepository!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        collections = CollectionRepository(database: database)
    }

    private func insertBook(_ id: String, collectionId: String? = nil, coverPath: String? = nil) async throws {
        let book = Book(
            id: id, title: id, author: nil, album: nil, durationMs: 1000, audioPath: "x",
            coverPath: coverPath, fileSize: 0, importedAt: Date(), epubPath: nil, syncPath: nil,
            collectionId: collectionId)
        try await database.writer.write { db in try book.insert(db) }
    }

    func testCreateAddObserve() async throws {
        let shelf = try await collections.create(name: "Shelf")
        try await insertBook("a", coverPath: "covers/a.jpg")
        try await insertBook("b")
        try await collections.addBook(bookId: "a", to: shelf.id)
        try await collections.addBook(bookId: "b", to: shelf.id)

        var iterator = collections.observeCollections().makeAsyncIterator()
        let items = try await iterator.next() ?? []
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].collection.name, "Shelf")
        XCTAssertEqual(items[0].bookCount, 2)
        XCTAssertEqual(items[0].coverPaths, ["covers/a.jpg"])
    }

    func testCollectionsSortedByName() async throws {
        _ = try await collections.create(name: "zebra")
        _ = try await collections.create(name: "Apple")
        var iterator = collections.observeCollections().makeAsyncIterator()
        let items = try await iterator.next() ?? []
        XCTAssertEqual(items.map(\.collection.name), ["Apple", "zebra"])
    }

    func testRemoveBookMovesToTopLevel() async throws {
        let shelf = try await collections.create(name: "Shelf")
        try await insertBook("a", collectionId: shelf.id)
        try await collections.removeBook(bookId: "a")
        let ids = try await collections.bookIds(in: shelf.id)
        XCTAssertEqual(ids, [])
        let book = try await database.writer.read { db in try Book.fetchOne(db, key: "a") }
        XCTAssertNil(book?.collectionId)
    }

    func testDeleteCollectionMovesBooksBack() async throws {
        let shelf = try await collections.create(name: "Shelf")
        try await insertBook("a", collectionId: shelf.id)
        try await collections.delete(collectionId: shelf.id)

        let book = try await database.writer.read { db in try Book.fetchOne(db, key: "a") }
        XCTAssertNotNil(book)
        XCTAssertNil(book?.collectionId) // FK ON DELETE SET NULL
        var iterator = collections.observeCollections().makeAsyncIterator()
        let items = try await iterator.next() ?? []
        XCTAssertEqual(items, [])
    }

    func testBookIdsInCollection() async throws {
        let shelf = try await collections.create(name: "Shelf")
        try await insertBook("a", collectionId: shelf.id)
        try await insertBook("b")
        let ids = try await collections.bookIds(in: shelf.id)
        XCTAssertEqual(ids, ["a"])
    }
}
