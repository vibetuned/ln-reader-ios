import Foundation
import GRDB

/// Where the reader left off in each book, keyed by book — the EPUB counterpart of
/// `PositionRepository`. Saved by the reader as the user pages and scrolls; read back when a book
/// is reopened, and by the library to draw progress for books that have no audio to measure by.
public final class ReadingPositionRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func get(bookId: String) async throws -> ReadingPosition? {
        try await database.writer.read { db in
            try ReadingPosition.fetchOne(db, key: bookId)
        }
    }

    /// bookId → saved reading position, for every book that has one.
    public func all() async throws -> [String: ReadingPosition] {
        try await database.writer.read { db in
            Dictionary(uniqueKeysWithValues: try ReadingPosition.fetchAll(db).map { ($0.bookId, $0) })
        }
    }

    public func save(bookId: String, spineIndex: Int, scrollFraction: Double, spineCount: Int) async throws {
        try await database.writer.write { db in
            // Same guard as PlaybackPosition: never resurrect a row for a deleted book.
            guard try Book.exists(db, key: bookId) else { return }
            try ReadingPosition(
                bookId: bookId,
                spineIndex: max(0, spineIndex),
                scrollFraction: min(1, max(0, scrollFraction)),
                spineCount: max(0, spineCount),
                updatedAt: Date()
            ).save(db)
        }
    }

    public func clear(bookId: String) async throws {
        _ = try await database.writer.write { db in
            try ReadingPosition.deleteOne(db, key: bookId)
        }
    }

    /// The most recent reading save, with its timestamp — weighed against the last playback save.
    public func lastRead() async throws -> LastActivity? {
        try await database.writer.read { db in
            try ReadingPosition
                .order(Column("updatedAt").desc)
                .fetchOne(db)
                .map { LastActivity(bookId: $0.bookId, updatedAt: $0.updatedAt) }
        }
    }
}
