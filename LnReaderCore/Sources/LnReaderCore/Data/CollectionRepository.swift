import Foundation
import GRDB

/// A collection joined with its live book count and contained cover art.
public struct CollectionListItem: Equatable, Identifiable, Sendable {
    public let collection: BookCollection
    public let bookCount: Int
    /// Cover paths of contained books (up to 9), for the shelf tile.
    public let coverPaths: [String]
    public var id: String { collection.id }
}

/// OS-folder-style groupings, mirroring Android: a single nullable
/// `book.collectionId` (no join table, no nesting); nil = top-level library.
public final class CollectionRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// All collections, name-sorted, each with count + covers for tile art.
    public func observeCollections() -> AsyncValueObservation<[CollectionListItem]> {
        ValueObservation
            .tracking { db in
                let collections = try BookCollection
                    .order(Column("name").collating(.localizedCaseInsensitiveCompare))
                    .fetchAll(db)
                return try collections.map { collection in
                    let books = try Book
                        .filter(Column("collectionId") == collection.id)
                        .order(Column("importedAt"))
                        .fetchAll(db)
                    return CollectionListItem(
                        collection: collection,
                        bookCount: books.count,
                        coverPaths: Array(books.compactMap(\.coverPath).prefix(9))
                    )
                }
            }
            .values(in: database.writer)
    }

    public func collection(id: String) async throws -> BookCollection? {
        try await database.writer.read { db in
            try BookCollection.fetchOne(db, key: id)
        }
    }

    @discardableResult
    public func create(name: String) async throws -> BookCollection {
        let collection = BookCollection(id: UUID().uuidString, name: name, createdAt: Date())
        try await database.writer.write { db in
            try collection.insert(db)
        }
        return collection
    }

    public func addBook(bookId: String, to collectionId: String) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE book SET collectionId = ? WHERE id = ?",
                arguments: [collectionId, bookId])
        }
    }

    /// Moves the book back to the top-level library.
    public func removeBook(bookId: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE book SET collectionId = NULL WHERE id = ?", arguments: [bookId])
        }
    }

    public func bookIds(in collectionId: String) async throws -> [String] {
        try await database.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM book WHERE collectionId = ?",
                arguments: [collectionId])
        }
    }

    /// Drops the collection row. Remaining books move back to the top level
    /// (the FK is ON DELETE SET NULL). To also delete the books, the caller
    /// deletes each via BookRepository first — file cleanup lives there.
    public func delete(collectionId: String) async throws {
        _ = try await database.writer.write { db in
            try BookCollection.deleteOne(db, key: collectionId)
        }
    }
}
